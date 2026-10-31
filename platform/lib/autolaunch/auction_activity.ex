defmodule Autolaunch.AuctionActivity do
  @moduledoc """
  A bounded, browser-independent projection of confirmed bids, the clearing
  prices the auction announced, and the withdraws and claims of its bids
  (`Autolaunch.BidSettlement`). Each pass reads one auction and at most 2,000
  blocks. The cursor and rows commit together;
  repeat ranges replace the same events. A changed cursor block invalidates this
  auction's derived activity and rebuilds it. On Base each bid also becomes its
  bidder's wallet position; a rebuild never removes or changes a saved one.

  Each listed auction has one job (`Autolaunch.ChainWatch` makes sure of it),
  which runs a pass and then waits: a second while the auction is behind the
  head, five minutes once it has caught up, ten once it has finished. A press
  that lands on its chain brings it forward to ten seconds away (`refresh/1`). A
  pass the node could not answer, or whose head moved under it, is one warning
  line and is read again a minute later; any other failure is a fault, tried
  again a minute later.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:auction_id], period: :infinity, states: :incomplete]

  @behaviour Autolaunch.ChainRefresh
  import Ecto.Query
  require Ash.Query
  require Logger
  alias Autolaunch.Actors.System

  alias Autolaunch.{
    Auction,
    AuctionPricePoint,
    Bid,
    BidActivity,
    BidPrice,
    BidSettlement,
    ChainWatch,
    LabAbi,
    LaunchChain,
    Repo
  }

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.ChainRefresh
  alias RegentChain.Address
  @actor %System{}
  # The node did not answer, or answered for a head that has since moved.
  @unavailable [
    :chain_unavailable,
    :logs_unavailable,
    :header_unavailable,
    :headers_unavailable,
    :history_unavailable,
    :sold_unavailable,
    :head_moved
  ]
  @bid "BidSubmitted(uint256,address,uint256,uint128)"
  @checkpoint "CheckpointUpdated(uint256,uint256,uint24)"
  @price "ClearingPriceUpdated(uint256,uint256)"
  @exited "BidExited(uint256,address,uint256,uint256)"
  @claimed "TokensClaimed(uint256,address,uint256)"
  @token_decimals 18
  @adapter_bid "StockBidPlaced(address,address,uint256,uint256,uint128,uint256)"
  @range 2_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"auction_id" => id}}) do
    case Ash.get(Auction, id, action: :activity, actor: @actor, not_found_error?: false) do
      {:ok, nil} ->
        {:cancel, :not_listed}

      {:ok, auction} ->
        case read(auction) do
          {:ok, :behind} ->
            {:snooze, 1}

          {:ok, :caught_up} ->
            {:snooze, wait_s(auction)}

          {:error, reason} when reason in @unavailable ->
            Logger.warning(
              "Bid activity for auction #{id} not read (#{reason}); reading again in a minute"
            )

            {:snooze, 60}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  @doc "Every listed auction's reading job (`Autolaunch.ChainWatch`)."
  def jobs, do: Enum.map(listed(), &new(%{auction_id: &1.id}))

  @doc """
  A person's on-chain press on chain `chain_id` landed: every listed auction on
  it is read ten seconds from now, instead of at its next turn. One already due
  sooner stays as it is.
  """
  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl ChainRefresh
  def refresh(chain_id) do
    if not Autolaunch.Prelaunch.read_only?() do
      Auction
      |> Ash.Query.filter(chain_id == ^chain_id)
      |> listed()
      |> Enum.each(&ChainWatch.soon(new(%{auction_id: &1.id})))
    end

    :ok
  end

  defp listed(query \\ Auction) do
    query
    |> Ash.Query.for_read(:activity, %{}, actor: @actor)
    |> Ash.Query.select([:id])
    |> Ash.read!()
  end

  defp wait_s(%{state: state}) when state in [:graduated, :failed], do: 600
  defp wait_s(_auction), do: 300

  def read(auction) do
    with {:ok, venue} <- venue(auction),
         {:ok, head} <- Rpc.latest_block(venue.opts),
         {:ok, clock} <- clock(venue, head),
         {:ok, start_block} <- uint(auction.auction_address, "startBlock()", head, venue.opts),
         {:ok, end_block} <- uint(auction.auction_address, "endBlock()", head, venue.opts),
         {:ok, first} <- first_block(auction, venue, head, start_block),
         :ok <- cursor_valid(auction, head, venue.opts),
         {:ok, last, logs} <- logs(auction, venue, first, min(first + @range - 1, head.number)),
         {:ok, headers} <- headers(logs, last, venue.opts),
         {:ok, bids, points, settlements} <- events(auction, venue, logs, headers, first),
         {:ok, current} <- header(head.number, venue.opts),
         :ok <- same_head(current, head) do
      timestamp = DateTime.from_unix!(current.timestamp, :second)
      rate = rate(auction, venue.chain)

      auction
      |> commit(
        first,
        last,
        headers[last].hash,
        {bids, points, settlements},
        {at(timestamp, clock, start_block, venue), at(timestamp, clock, end_block, venue)},
        rate,
        last == head.number
      )
      |> indexed(auction, bids, head.number - last)
    else
      {:error, :cursor_changed} -> invalidate(auction)
      {:error, reason} -> {:error, reason}
    end
  end

  # The head moved while the pass read, so its blocks are read again.
  defp same_head(%{hash: hash}, %{hash: hash}), do: :ok
  defp same_head(_current, _head), do: {:error, :head_moved}

  # After a committed pass: how far the auction's cursor trails the head, and
  # how long after its block each bid first seen by a pass that reached the
  # head from an existing cursor got to the site. A first pass or a rebuild
  # reads history rather than new bids, so it is left out. Answers whether the
  # auction has caught up with the head.
  defp indexed(:ok, auction, bids, behind) do
    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: behind},
      %{indexer: :auction_activity, chain_id: auction.chain_id}
    )

    if behind == 0 and is_integer(auction.activity_next_block) do
      now = DateTime.utc_now()

      for %{block_number: number, occurred_at: at} <- bids,
          number >= auction.activity_next_block,
          do:
            :telemetry.execute(
              [:autolaunch, :chain_event, :recorded],
              %{delay_ms: DateTime.diff(now, at, :millisecond)},
              %{kind: :bid, chain_id: auction.chain_id}
            )
    end

    {:ok, if(behind == 0, do: :caught_up, else: :behind)}
  end

  defp indexed(error, _auction, _bids, _behind), do: error

  defp venue(%{chain_id: chain, kind: kind} = auction) do
    {module, network} =
      cond do
        Autolaunch.Robinhood.Lab.chain?(chain) -> {Autolaunch.Robinhood.Lab, :robinhood}
        kind == :stocks -> {Autolaunch.Stocks.Lab, :base}
        true -> {Autolaunch.Lab, :base}
      end

    with {:ok, config} <- module.current(),
         true <- config.chain_id == chain,
         {:ok, adapter} <- adapter(module, config, auction) do
      opts =
        if module == Autolaunch.Lab,
          do: Autolaunch.LabRpc.opts(config, "auction activity"),
          else: module.rpc_opts(config)

      {:ok, %{opts: opts, chain: network, adapter: adapter}}
    else
      _unavailable -> {:error, :chain_unavailable}
    end
  end

  # A Memestock auction's adapter bids went through the bid adapter of its own
  # contracts version.
  defp adapter(Autolaunch.Lab, config, _auction), do: {:ok, config.addresses["bid_adapter"]}

  defp adapter(module, config, %{contracts_version: version}) do
    with {:ok, contracts} <- module.contracts(config, version), do: {:ok, contracts.bid_adapter}
  end

  # When the contract clock reaches the block, estimated from the head's time.
  defp at(timestamp, clock, block, venue),
    do: DateTime.add(timestamp, round(LaunchChain.seconds(venue.chain, block - clock)))

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
    do: Rpc.deployment_block(auction.auction_address, head.number, venue.opts)

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
      Map.merge(range, %{
        address: auction.auction_address,
        topics: [
          [
            LabAbi.topic(@bid),
            LabAbi.topic(@checkpoint),
            LabAbi.topic(@price),
            LabAbi.topic(@exited),
            LabAbi.topic(@claimed)
          ]
        ]
      })

    # Scope the adapter query to this auction, not every auction on the network.
    adapter_filter =
      Map.merge(range, %{
        address: venue.adapter,
        topics: [LabAbi.topic(@adapter_bid), address_topic(auction.auction_address)]
      })

    filters = if venue.adapter, do: [bid_filter, adapter_filter], else: [bid_filter]

    case map_ok(filters, &read_logs(&1, venue.opts)) do
      {:ok, batches} ->
        rows = List.flatten(batches)

        if Enum.count_until(rows, 201) > 200 and first < last,
          do: logs(auction, venue, first, div(first + last, 2)),
          else: {:ok, last, rows}

      _ when first < last ->
        logs(auction, venue, first, div(first + last, 2))

      error ->
        error
    end
  end

  defp read_logs(filter, opts) do
    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      _ -> {:error, :logs_unavailable}
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
        &numbered_header(&1, opts),
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

  defp numbered_header(number, opts) do
    with {:ok, value} <- header(number, opts), do: {:ok, {number, value}}
  end

  # The auction's logs in chain order. Every bid runs a checkpoint first, and
  # the contract announces a block's checkpoint only once, so a bid belongs to
  # the clock block of the latest price event at or before it; that event may
  # sit in an earlier range, which the stored price points hold.
  defp events(auction, venue, logs, headers, first) do
    with {:ok, positioned} <-
           logs
           |> Enum.filter(&Address.equal?(&1["address"], auction.auction_address))
           |> map_ok(&positioned(&1, headers)),
         {:ok, clock} <- stored_clock(auction, first),
         {:ok, _clock, {bids, points, settlements}} <-
           read_events(positioned, clock, &event(auction, venue, logs, headers, &1, &2, &3)),
         {:ok, points} <- with_sold(points, auction, headers, venue.opts),
         do: {:ok, bids, points, settlements}
  end

  defp read_events(positioned, clock, read) do
    positioned
    |> Enum.sort_by(fn {position, _log} -> position end)
    |> Enum.reduce_while({:ok, clock, {[], [], []}}, fn {position, log},
                                                        {:ok, clock, {bids, points, settled}} ->
      case read.(position, log, clock) do
        {:point, point} -> {:cont, {:ok, point.clock_block, {bids, [point | points], settled}}}
        {:bid, bid} -> {:cont, {:ok, clock, {[bid | bids], points, settled}}}
        {:settlement, row} -> {:cont, {:ok, clock, {bids, points, [row | settled]}}}
        error -> {:halt, error}
      end
    end)
  end

  defp positioned(log, headers) do
    with false <- log["removed"],
         {:ok, number} <- quantity(log["blockNumber"]),
         {:ok, index} <- quantity(log["logIndex"]),
         true <- String.downcase(log["blockHash"]) == headers[number].hash do
      {:ok, {{number, index}, log}}
    else
      _ -> {:error, :invalid_bid_event}
    end
  end

  defp stored_clock(auction, first) do
    with {:ok, point} <-
           Autolaunch.latest_price_point_before(auction.id, first, actor: @actor),
         do: {:ok, point && point.clock_block}
  end

  defp event(auction, venue, logs, headers, {number, index}, log, clock) do
    checkpoint = LabAbi.topic(@checkpoint)
    price = LabAbi.topic(@price)
    bid = LabAbi.topic(@bid)
    exited = LabAbi.topic(@exited)
    claimed = LabAbi.topic(@claimed)

    case {log["topics"], words(log["data"])} do
      {[^checkpoint], {:ok, [at, clearing, _released]}} ->
        {:point, point(auction, number, index, at, clearing)}

      {[^price], {:ok, [at, clearing]}} ->
        {:point, point(auction, number, index, at, clearing)}

      {[^bid, id, owner], {:ok, [max_price, atomic]}} when is_integer(clock) ->
        with {:ok, bid_id} <- quantity(id),
             {:ok, bidder} <- topic_address(owner) do
          amount = Decimal.new(Rpc.format_units(atomic, auction.quote_token_decimals))
          {shown, symbol} = display(auction, venue, log, id, logs, amount)

          {:bid,
           %{
             auction_id: auction.id,
             bid_id: Integer.to_string(bid_id),
             bidder: bidder,
             transaction_hash: log["transactionHash"],
             block_hash: headers[number].hash,
             block_number: number,
             log_index: index,
             clock_block: clock,
             occurred_at: DateTime.from_unix!(headers[number].timestamp),
             amount: amount,
             display_amount: shown,
             display_symbol: symbol,
             max_price: price(max_price, auction)
           }}
        end

      {[^exited, id, owner], {:ok, [filled, refunded]}} ->
        settlement(auction, headers, {number, index}, log, {id, owner}, %{
          kind: :exit,
          currency: Decimal.new(Rpc.format_units(refunded, auction.quote_token_decimals)),
          tokens: Decimal.new(Rpc.format_units(filled, @token_decimals))
        })

      {[^claimed, id, owner], {:ok, [tokens]}} ->
        settlement(auction, headers, {number, index}, log, {id, owner}, %{
          kind: :claim,
          currency: nil,
          tokens: Decimal.new(Rpc.format_units(tokens, @token_decimals))
        })

      _ ->
        {:error, :invalid_bid_event}
    end
  end

  defp settlement(auction, headers, {number, index}, log, {id, owner}, amounts) do
    with {:ok, bid_id} <- quantity(id),
         {:ok, owner} <- topic_address(owner) do
      {:settlement,
       Map.merge(amounts, %{
         auction_id: auction.id,
         bid_id: Integer.to_string(bid_id),
         owner: owner,
         transaction_hash: log["transactionHash"],
         block_hash: headers[number].hash,
         block_number: number,
         log_index: index,
         occurred_at: DateTime.from_unix!(headers[number].timestamp)
       })}
    end
  end

  # What the auction had raised by the end of each price event's block.
  defp with_sold(points, auction, headers, opts) do
    points
    |> Enum.map(& &1.block_number)
    |> Enum.uniq()
    |> Task.async_stream(
      fn number ->
        with {:ok, raised} <-
               uint(auction.auction_address, "currencyRaised()", headers[number], opts),
             do: {:ok, {number, raised}}
      end,
      max_concurrency: 4,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {:ok, {number, raised}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, number, raised)}}
      _, _ -> {:halt, {:error, :sold_unavailable}}
    end)
    |> case do
      {:ok, sold} ->
        {:ok,
         Enum.map(points, fn point ->
           raised = Rpc.format_units(sold[point.block_number], auction.quote_token_decimals)
           Map.put(point, :sold, Decimal.new(raised))
         end)}

      error ->
        error
    end
  end

  defp point(auction, number, index, at, clearing),
    do: %{
      auction_id: auction.id,
      block_number: number,
      log_index: index,
      clock_block: at,
      clearing_price: price(clearing, auction)
    }

  defp price(q96, auction),
    do: Decimal.new(BidPrice.decimal(q96, auction.quote_token_decimals), max_digits: :infinity)

  defp words("0x" <> data) when rem(byte_size(data), 64) == 0 do
    for <<word::binary-size(64) <- data>>, reduce: {:ok, []} do
      {:ok, acc} ->
        case Integer.parse(word, 16) do
          {value, ""} -> {:ok, acc ++ [value]}
          _ -> {:error, :invalid_word}
        end

      error ->
        error
    end
  end

  defp words(_data), do: {:error, :invalid_word}

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

  # This system projection locks its parent auction before replacing confirmed
  # events and aggregating their exact amounts in SQL. Notifications come only
  # from the parent Ash update after the enclosing transaction commits.
  defp commit(
         auction,
         first,
         last,
         hash,
         {bids, points, settlements},
         {opening, ending},
         rate,
         complete?
       ) do
    Repo.transaction(fn ->
      current =
        Auction
        |> Ash.Query.for_read(
          :by_chain_address,
          %{chain_id: auction.chain_id, auction_address: auction.auction_address},
          actor: @actor
        )
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!()

      if current.activity_next_block != auction.activity_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(
        from b in BidActivity, where: b.auction_id == ^auction.id and b.block_number >= ^first
      )

      Repo.delete_all(
        from p in AuctionPricePoint,
          where: p.auction_id == ^auction.id and p.block_number >= ^first
      )

      Repo.delete_all(
        from s in BidSettlement, where: s.auction_id == ^auction.id and s.block_number >= ^first
      )

      Ash.bulk_create!(bids, BidActivity, :record, actor: @actor, return_errors?: true)
      Ash.bulk_create!(points, AuctionPricePoint, :record, actor: @actor, return_errors?: true)

      Ash.bulk_create!(settlements, BidSettlement, :record,
        actor: @actor,
        return_errors?: true
      )

      record_positions(auction)

      total =
        Repo.one(from b in BidActivity, where: b.auction_id == ^auction.id, select: sum(b.amount)) ||
          Decimal.new(0)

      Ash.update!(
        current,
        %{
          activity_next_block: last + 1,
          activity_last_hash: hash,
          opened_at: opening,
          estimated_end_at: ending,
          bid_volume: if(complete?, do: total),
          bid_volume_usd: dollar_volume(total, rate, complete?),
          events_changed: new_events?(current, bids ++ points ++ settlements)
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

  # Whether the pass saved an event the lists do not have yet. A pass that
  # finds no new block reads its last block again; `cursor_valid/3` has checked
  # that block is the one already saved, so its events are the same rows.
  defp new_events?(%{activity_next_block: nil}, events), do: events != []

  defp new_events?(%{activity_next_block: next}, events),
    do: Enum.any?(events, &(&1.block_number >= next))

  # Every bid a Base auction announced is also its bidder's position, whether or
  # not their page was open when it confirmed. Only bids without a saved position
  # are written, so a pass never touches one being settled. Robinhood positions
  # are read from the chain when the bidder looks, so none are saved here.
  defp record_positions(auction) do
    unless Autolaunch.Robinhood.Lab.chain?(auction.chain_id), do: record_base_positions(auction)
  end

  defp record_base_positions(auction) do
    saved =
      from b in Bid,
        where: b.auction_id == ^auction.id and not is_nil(b.onchain_bid_id),
        select: b.onchain_bid_id

    # One SQL anti-join between two system-owned tables, inside the same locked
    # transaction as the commit; the writes still go through the Ash action.
    from(a in BidActivity, where: a.auction_id == ^auction.id and a.bid_id not in subquery(saved))
    |> Repo.all()
    |> Enum.map(&position(auction, &1))
    |> Ash.bulk_create!(Bid, :record_from_chain, actor: @actor, return_errors?: true)
  end

  defp position(auction, activity),
    do: %{
      bid_id: Autolaunch.LabProjection.bid_identity(auction.auction_address, activity.bid_id),
      auction_id: auction.id,
      owner_address: activity.bidder,
      amount: Decimal.to_string(activity.amount, :normal),
      max_price: Decimal.to_string(activity.max_price, :normal),
      auction_address: auction.auction_address,
      onchain_bid_id: activity.bid_id
    }

  defp dollar_volume(_total, nil, _complete?), do: nil
  defp dollar_volume(total, rate, true), do: Decimal.mult(total, rate)
  defp dollar_volume(_total, _rate, false), do: nil

  # Invalidation removes only derived event rows while holding the parent lock;
  # Ash clears its cursor and broadcasts that change after this transaction. The
  # auction is then behind, and rebuilt from its first block at once.
  defp invalidate(auction) do
    Repo.transaction(fn ->
      current =
        Auction
        |> Ash.Query.for_read(
          :by_chain_address,
          %{chain_id: auction.chain_id, auction_address: auction.auction_address},
          actor: @actor
        )
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!()

      if current.activity_next_block != auction.activity_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(from b in BidActivity, where: b.auction_id == ^auction.id)
      Repo.delete_all(from p in AuctionPricePoint, where: p.auction_id == ^auction.id)
      Repo.delete_all(from s in BidSettlement, where: s.auction_id == ^auction.id)

      Ash.update!(
        current,
        %{
          activity_next_block: nil,
          activity_last_hash: nil,
          bid_volume: nil,
          bid_volume_usd: nil,
          estimated_end_at: nil,
          events_changed: true
        },
        actor: @actor,
        action: :refresh_activity,
        return_notifications?: true
      )
    end)
    |> case do
      {:ok, {_updated, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, :behind}

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

  defp topic_address("0x000000000000000000000000" <> address) when byte_size(address) == 40,
    do: {:ok, "0x" <> String.downcase(address)}

  defp topic_address(_topic), do: {:error, :invalid_bid_event}

  defp address_topic("0x" <> address),
    do: "0x" <> String.pad_leading(String.downcase(address), 64, "0")
end
