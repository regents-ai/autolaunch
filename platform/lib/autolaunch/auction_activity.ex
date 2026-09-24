defmodule Autolaunch.AuctionActivity do
  @moduledoc """
  A bounded, browser-independent projection of confirmed bids. Each pass reads
  one auction and at most 2,000 blocks. The cursor and rows commit together;
  repeat ranges replace the same bids. A changed cursor block invalidates this
  auction's derived activity and rebuilds it, without touching wallet positions.
  """
  @behaviour Autolaunch.DurableWork.Handler
  import Ecto.Query
  require Ash.Query
  require Logger
  alias Autolaunch.{Auction, BidActivity, LabAbi, Repo}
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Address, Rpc}
  @actor %System{}
  @bid "BidSubmitted(uint256,address,uint256,uint128)"
  @adapter_bid "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @range 2_000

  def poll(_, 0), do: []
  def poll(_, _), do: [:next]

  def handle(historical, :next) do
    case claim(historical) do
      {:ok, nil} ->
        :ok

      {:ok, auction} ->
        case refresh(auction) do
          :ok ->
            :ok

          _ ->
            Logger.warning("Bid activity unavailable for auction #{auction.id}; retry scheduled")
            :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp claim(historical) do
    Repo.transaction(fn ->
      case Auction
           |> Ash.Query.for_read(:activity_due, %{historical: historical}, actor: @actor)
           |> Ash.read!() do
        [] ->
          nil

        [auction] ->
          Ash.update!(auction, %{activity_due_at: DateTime.add(DateTime.utc_now(), 60)},
            action: :schedule_activity,
            actor: @actor
          )
      end
    end)
  end

  def refresh(auction) do
    with {:ok, venue} <- venue(auction),
         {:ok, head} <- Rpc.latest_block(venue.opts),
         {:ok, clock} <- clock(venue, head),
         {:ok, start_block} <- uint(auction.auction_address, "startBlock()", head, venue.opts),
         {:ok, end_block} <- uint(auction.auction_address, "endBlock()", head, venue.opts),
         {:ok, first} <- first_block(auction, venue, head, start_block),
         :ok <- cursor_valid(auction, head, venue.opts),
         {:ok, last, logs} <- logs(auction, venue, first, min(first + @range - 1, head.number)),
         {:ok, headers} <- headers(logs, last, venue.opts),
         {:ok, events} <- events(auction, venue, logs, headers),
         {:ok, current} <- header(head.number, venue.opts),
         true <- current.hash == head.hash do
      timestamp = DateTime.from_unix!(current.timestamp, :second)
      seconds = round((end_block - clock) * if(venue.chain == :base, do: 2, else: 0.1))
      ending = DateTime.add(timestamp, seconds)
      rate = rate(auction, venue.chain)
      commit(auction, first, last, headers[last].hash, events, ending, rate, last == head.number)
    else
      {:error, :cursor_changed} -> invalidate(auction)
      _ -> {:error, :activity_unavailable}
    end
  end

  defp venue(%{chain_id: chain, kind: kind}) do
    {module, network} =
      cond do
        Autolaunch.Robinhood.Lab.chain?(chain) -> {Autolaunch.Robinhood.Lab, :robinhood}
        kind == :stocks -> {Autolaunch.Stocks.Lab, :base}
        true -> {Autolaunch.Lab, :base}
      end

    with {:ok, config} <- module.current(),
         true <- config.chain_id == chain do
      opts =
        if module == Autolaunch.Lab,
          do: Autolaunch.LabRpc.opts(config, "auction activity"),
          else: module.rpc_opts(config)

      {:ok, %{opts: opts, chain: network, adapter: config.addresses["bid_adapter"]}}
    end
  end

  defp clock(%{chain: :base}, head), do: {:ok, head.number}
  defp clock(venue, head), do: Autolaunch.Robinhood.BlockClock.read(head, venue.opts)

  defp uint(address, signature, head, opts),
    do: Rpc.call_uint(address, LabAbi.selector(signature), head, opts)

  defp first_block(%{activity_next_block: next}, _, head, _) when is_integer(next),
    do: {:ok, min(next, head.number)}

  defp first_block(_, %{chain: :base}, head, start), do: {:ok, min(start, head.number)}
  # The Robinhood contract clock may differ from EVM log heights (especially on
  # a fork). Find deployment from code history; never reinterpret clock blocks.
  defp first_block(auction, venue, head, _),
    do: deployment_block(auction.auction_address, 0, head.number, venue.opts)

  defp deployment_block(_, same, same, _), do: {:ok, same}

  defp deployment_block(address, low, high, opts) do
    middle = div(low + high, 2)

    case Rpc.request("eth_getCode", [address, hex(middle)], opts) do
      {:ok, "0x"} -> deployment_block(address, middle + 1, high, opts)
      {:ok, "0x" <> code} when byte_size(code) > 0 -> deployment_block(address, low, middle, opts)
      _ -> {:error, :history_unavailable}
    end
  end

  defp cursor_valid(%{activity_next_block: nil}, _, _), do: :ok

  defp cursor_valid(%{activity_next_block: next}, %{number: head}, _) when next > head + 1,
    do: {:error, :cursor_changed}

  defp cursor_valid(auction, _, opts) do
    case header(auction.activity_next_block - 1, opts) do
      {:ok, %{hash: hash}} when hash == auction.activity_last_hash -> :ok
      {:ok, _} -> {:error, :cursor_changed}
      _ -> {:error, :history_unavailable}
    end
  end

  defp logs(auction, venue, first, last) do
    range = %{fromBlock: hex(first), toBlock: hex(last)}

    bid_filter =
      Map.merge(range, %{address: auction.auction_address, topics: [LabAbi.topic(@bid)]})

    # Scope the adapter query to this auction, not every auction on the network.
    adapter_filter =
      Map.merge(range, %{
        address: venue.adapter,
        topics: [LabAbi.topic(@adapter_bid), address_topic(auction.auction_address)]
      })

    filters = if venue.adapter, do: [bid_filter, adapter_filter], else: [bid_filter]

    with {:ok, batches} <-
           map_ok(filters, fn filter ->
             case Rpc.request("eth_getLogs", [filter], venue.opts) do
               {:ok, rows} when is_list(rows) -> {:ok, rows}
               _ -> {:error, :logs_unavailable}
             end
           end) do
      rows = List.flatten(batches)

      if length(rows) > 200 and first < last,
        do: logs(auction, venue, first, div(first + last, 2)),
        else: {:ok, last, rows}
    else
      _ when first < last -> logs(auction, venue, first, div(first + last, 2))
      error -> error
    end
  end

  defp header(number, opts) do
    with {:ok, %{"hash" => hash, "timestamp" => timestamp}} <-
           Rpc.request("eth_getBlockByNumber", [hex(number), false], opts),
         true <- Rpc.valid_hash?(hash),
         {:ok, seconds} <- quantity(timestamp) do
      {:ok, %{hash: String.downcase(hash), timestamp: seconds}}
    else
      _ -> {:error, :header_unavailable}
    end
  end

  defp headers(logs, last, opts) do
    with {:ok, numbers} <- map_ok(logs, &quantity(&1["blockNumber"])) do
      (numbers ++ [last])
      |> Enum.uniq()
      |> Task.async_stream(
        fn number ->
          with {:ok, value} <- header(number, opts), do: {:ok, {number, value}}
        end,
        max_concurrency: 4,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {:ok, {number, value}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, number, value)}}
        _, _ -> {:halt, {:error, :headers_unavailable}}
      end)
    end
  end

  defp events(auction, venue, logs, headers) do
    bids = Enum.filter(logs, &Address.equal?(&1["address"], auction.auction_address))

    map_ok(bids, fn log ->
      with false <- log["removed"],
           [topic, id, _owner] <- log["topics"],
           true <- topic == LabAbi.topic(@bid),
           {:ok, bid_id} <- quantity(id),
           {:ok, number} <- quantity(log["blockNumber"]),
           true <- String.downcase(log["blockHash"]) == headers[number].hash,
           "0x" <> <<_price::binary-size(64), amount::binary-size(64)>> <- log["data"],
           {atomic, ""} <- Integer.parse(amount, 16) do
        amount = Decimal.new(Rpc.format_units(atomic, auction.quote_token_decimals))
        {shown, symbol} = display(auction, venue, log, id, logs, amount)

        {:ok,
         %{
           auction_id: auction.id,
           bid_id: Integer.to_string(bid_id),
           transaction_hash: log["transactionHash"],
           block_hash: headers[number].hash,
           block_number: number,
           occurred_at: DateTime.from_unix!(headers[number].timestamp),
           amount: amount,
           display_amount: shown,
           display_symbol: symbol
         }}
      else
        _ -> {:error, :invalid_bid_event}
      end
    end)
  end

  defp display(auction, venue, bid, id, logs, amount) do
    event =
      Enum.find(logs, fn log ->
        Address.equal?(log["address"], venue.adapter) and
          log["transactionHash"] == bid["transactionHash"] and
          log["blockHash"] == bid["blockHash"] and log["removed"] == false and
          log["topics"] == [
            LabAbi.topic(@adapter_bid),
            address_topic(auction.auction_address),
            Enum.at(bid["topics"], 2),
            id
          ]
      end)

    case event do
      %{"data" => "0x" <> <<spent::binary-size(64), _rest::binary-size(128)>>} ->
        {Decimal.new(Rpc.format_units(String.to_integer(spent, 16), 6)),
         if(venue.chain == :base, do: "USDC", else: "USDG")}

      _ ->
        {amount, auction.quote_token_symbol}
    end
  end

  defp rate(%{quote_token_symbol: "REGENT"}, _), do: Autolaunch.Stocks.MarketData.regent_price()

  defp rate(auction, chain),
    do: Autolaunch.Stocks.MarketData.stock_price(chain, auction.quote_token_symbol)

  defp commit(auction, first, last, hash, events, ending, rate, complete?) do
    Repo.transaction(fn ->
      current =
        Auction
        |> Ash.Query.for_read(:listed_by_id, %{id: auction.id}, actor: @actor)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!()

      if current.activity_next_block != auction.activity_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(
        from b in BidActivity, where: b.auction_id == ^auction.id and b.block_number >= ^first
      )

      Enum.each(events, &Ash.create!(BidActivity, &1, actor: @actor, action: :record))

      total =
        Repo.one(from b in BidActivity, where: b.auction_id == ^auction.id, select: sum(b.amount)) ||
          Decimal.new(0)

      delay =
        cond do
          not complete? -> 1
          current.state in [:graduated, :failed] -> 600
          true -> 5
        end

      Ash.update!(
        current,
        %{
          activity_next_block: last + 1,
          activity_last_hash: hash,
          activity_due_at: DateTime.add(DateTime.utc_now(), delay),
          estimated_end_at: ending,
          bid_volume: if(complete?, do: total),
          bid_volume_usd: if(complete? and not is_nil(rate), do: Decimal.mult(total, rate))
        },
        actor: @actor,
        action: :refresh_activity,
        return_notifications?: true
      )
    end)
    |> case do
      {:ok, {_updated, notifications}} ->
        Ash.Notifier.notify(notifications)
        :ok

      error ->
        error
    end
  end

  defp invalidate(auction) do
    Repo.transaction(fn ->
      current =
        Auction
        |> Ash.Query.for_read(:listed_by_id, %{id: auction.id}, actor: @actor)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!()

      if current.activity_next_block != auction.activity_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(from b in BidActivity, where: b.auction_id == ^auction.id)

      Ash.update!(
        current,
        %{
          activity_next_block: nil,
          activity_last_hash: nil,
          bid_volume: nil,
          bid_volume_usd: nil,
          estimated_end_at: nil,
          activity_due_at: DateTime.utc_now()
        },
        actor: @actor,
        action: :refresh_activity,
        return_notifications?: true
      )
    end)
    |> case do
      {:ok, {_updated, notifications}} ->
        Ash.Notifier.notify(notifications)
        :ok

      error ->
        error
    end
  end

  defp map_ok(items, read) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp quantity("0x" <> value) do
    case Integer.parse(value, 16) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp quantity(_), do: {:error, :invalid_quantity}
  defp hex(value), do: "0x" <> Integer.to_string(max(0, value), 16)

  defp address_topic("0x" <> address),
    do: "0x" <> String.pad_leading(String.downcase(address), 64, "0")
end
