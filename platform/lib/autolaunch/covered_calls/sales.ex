defmodule Autolaunch.CoveredCalls.Sales do
  @moduledoc """
  Reads each covered-call market's contract for calls that changed hands and
  saves each once (`Autolaunch.CoveredCalls.Sale`), at the latest block, so
  Regent Points can offer its seller and its buyer their award.

  Two logs are sales: `Filled`, a buyer buying from a listing, and `SoldToBid`,
  a seller selling into a bid. Each names one side as the wallet that called
  the contract; the other is read from the contract at the head, the listing's
  seller or the bid's bidder, both fixed when the listing or bid was made.
  `Listed` and `BidPosted` alone are no sale and are not read.

  Each market has one job (`Autolaunch.ChainWatch` makes sure of it while
  covered calls are on). The first pass opens the contract's cursor at the
  block it was deployed in. Each pass reads the head, then, in one log search
  of at most 10,000 blocks that the node may make smaller, the last 300 blocks
  it already read (one minute of Base) and the new ones after them, and saves
  the sales and moves the cursor in one transaction. A sale it reads again
  must match the saved row, and every saved sale in those 300 blocks must
  still sit in a block of the same hash; if not, the chain changed under the
  record, and the contract's cursor stops
  at the earliest such block until an operator puts the record right and
  clears it (`bin/clear-covered-call-sales-stop`). The job then waits a second
  while the contract is behind the head and five minutes once it has caught
  up; a node that does not answer is one warning line and a minute's wait. It
  does nothing while covered calls are off or their contracts are not
  described.
  """
  use Oban.Worker,
    queue: :chain,
    max_attempts: 20,
    unique: [keys: [:contract], period: :infinity, states: :incomplete]

  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Chain, Cursor, Deployment, Diverged}
  alias Autolaunch.Repo
  alias RegentChain.{Address, Event}

  @actor %System{}
  @reread 300
  @stretch 10_000
  @events %{
    "Filled(uint256,address,uint256,uint256,uint256)" => :filled,
    "SoldToBid(uint256,uint256,address,uint256,uint256,uint256)" => :sold_to_bid
  }
  # The node did not answer, answered with something that is not a block, or
  # answered for a block that has since moved.
  @unavailable [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :wrong_chain,
    :history_unavailable,
    :headers_unavailable,
    :head_moved
  ]

  @doc "Each covered-call market's reading job, none while covered calls are off (`Autolaunch.ChainWatch`)."
  def jobs do
    case Deployment.current() do
      {:ok, config} -> Enum.map(config.markets, &new(%{contract: &1.contract}))
      {:error, _off} -> []
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"contract" => contract}}) do
    with {:ok, config} <- Deployment.current(),
         %{} = market <-
           Enum.find(config.markets, &(&1.contract == contract)) || {:error, :unknown_market} do
      market |> read(config.lab) |> next(market)
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 60

  defp next({:ok, :behind}, _market), do: {:snooze, 1}
  defp next({:ok, :caught_up}, _market), do: {:snooze, 300}

  defp next({:stopped, block}, market) do
    Logger.error(
      "Covered-call sales on #{market.contract} stopped at block #{block}: " <>
        "the chain disagrees with the record"
    )

    {:snooze, 300}
  end

  defp next({:error, reason}, market) when reason in @unavailable do
    Logger.warning(
      "Covered-call sales on #{market.contract} not read (#{reason}); reading again in a minute"
    )

    {:snooze, 60}
  end

  defp next({:error, reason}, _market), do: {:error, reason}

  defp read(market, lab) do
    with {:ok, cursor} <-
           CoveredCalls.covered_call_cursor(market.chain_id, market.contract, actor: @actor),
         :ok <- running(cursor),
         {:ok, head, opts} <- Chain.latest(lab),
         {:ok, cursor} <- opened(cursor, market, head, opts) do
      pass(cursor, market, head, opts)
    end
  end

  defp running(%{rescan_from: block}) when is_integer(block), do: {:stopped, block}
  defp running(_cursor), do: :ok

  defp opened(nil, market, head, opts) do
    with {:ok, block} <- Rpc.deployment_block(market.contract, head.number, opts) do
      CoveredCalls.open_covered_call_cursor(
        %{chain_id: market.chain_id, contract: market.contract, next_block: block},
        actor: @actor
      )
    end
  end

  defp opened(cursor, _market, _head, _opts), do: {:ok, cursor}

  # A head below the cursor is a node answering behind the one that answered
  # last time, not a change of the chain: there is nothing new to read.
  defp pass(%{next_block: next}, _market, %{number: head}, _opts) when next > head,
    do: {:ok, :caught_up}

  defp pass(cursor, market, head, opts) do
    from = max(cursor.next_block - @reread, 0)
    to = min(head.number, from + @stretch - 1)
    topics = Map.new(@events, fn {signature, event} -> {Event.topic0(signature), event} end)

    with {:ok, logs} <- Rpc.logs(market.contract, [Map.keys(topics)], from, to, opts),
         {:ok, saved} <-
           CoveredCalls.covered_call_sales_in_blocks(
             market.chain_id,
             market.contract,
             from,
             cursor.next_block - 1,
             actor: @actor
           ),
         {:ok, headers} <- headers(logs, saved, opts),
         :ok <- unchanged(saved, headers),
         {:ok, sales} <- map_ok(logs, &sale(&1, market, topics, headers)),
         {:ok, sales} <- counterparties(sales, market, head, opts) do
      cursor |> commit(sales, to, head) |> indexed(market, head)
    else
      {:moved, block} -> stop(cursor, block)
      {:error, reason} -> {:error, reason}
    end
  end

  # The blocks of the logs read and of the sales saved. A log without a block
  # number is refused when it is read (`sale/4`).
  defp headers(logs, saved, opts) do
    numbers = for log <- logs, {:ok, number} <- [quantity(log["blockNumber"])], do: number

    (numbers ++ Enum.map(saved, & &1.block_number))
    |> Enum.uniq()
    |> Task.async_stream(&header(&1, opts),
      max_concurrency: 4,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {:ok, {number, header}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, number, header)}}
      _failed, _acc -> {:halt, {:error, :headers_unavailable}}
    end)
  end

  defp header(number, opts) do
    with {:ok, %{"hash" => hash, "timestamp" => timestamp}} <-
           Rpc.request(
             "eth_getBlockByNumber",
             ["0x" <> Integer.to_string(number, 16), false],
             opts
           ),
         true <- Rpc.valid_hash?(hash),
         {:ok, seconds} <- quantity(timestamp) do
      {:ok, {number, %{hash: String.downcase(hash), timestamp: seconds}}}
    else
      _unavailable -> {:error, :header_unavailable}
    end
  end

  # Every saved sale the pass reads again must still sit in its block: one
  # whose block now has another hash was taken out of the chain.
  defp unchanged(saved, headers) do
    case for(sale <- saved, headers[sale.block_number].hash != sale.block_hash, do: sale) do
      [] -> :ok
      moved -> {:moved, moved |> Enum.map(& &1.block_number) |> Enum.min()}
    end
  end

  # One sale log as its row, in its block as the pass read it. A log from
  # another block than the one read under its number is from a chain that has
  # since moved, and the pass is read again.
  defp sale(log, market, topics, headers) do
    with {:ok, sale} <- decoded(log, market, topics) do
      %{hash: hash, timestamp: seconds} = headers[sale.block_number]

      if String.downcase(log["blockHash"]) == hash,
        do:
          {:ok, Map.merge(sale, %{block_hash: hash, occurred_at: DateTime.from_unix!(seconds)})},
        else: {:error, :head_moved}
    end
  end

  defp decoded(log, market, topics) do
    with false <- log["removed"],
         true <- Address.equal?(log["address"], market.contract),
         {:ok, number} <- quantity(log["blockNumber"]),
         {:ok, index} <- quantity(log["logIndex"]),
         true <- Rpc.valid_hash?(log["transactionHash"]) and Rpc.valid_hash?(log["blockHash"]),
         [topic | indexed] when is_binary(topic) <- log["topics"],
         {:ok, event} <- Map.fetch(topics, String.downcase(topic)),
         {:ok, sides} <- sides(event, indexed),
         {:ok, amounts} <- amounts(log["data"]) do
      {:ok,
       %{
         chain_id: market.chain_id,
         contract: market.contract,
         stock: market.stock,
         event: event,
         transaction_hash: String.downcase(log["transactionHash"]),
         log_index: index,
         block_number: number
       }
       |> Map.merge(sides)
       |> Map.merge(amounts)}
    else
      _malformed -> {:error, :invalid_covered_call_sale}
    end
  end

  # `Filled(listingId, buyer)` names the buyer; `SoldToBid(bidId, listingId,
  # seller)` the seller.
  defp sides(:filled, [listing, buyer]) do
    with {:ok, [listing, buyer]} <- words([listing, buyer]),
         {:ok, buyer} <- Event.address(buyer),
         do: {:ok, %{listing_id: listing, bid_id: nil, buyer: buyer}}
  end

  defp sides(:sold_to_bid, [bid, listing, seller]) do
    with {:ok, [bid, listing, seller]} <- words([bid, listing, seller]),
         {:ok, seller} <- Event.address(seller),
         do: {:ok, %{listing_id: listing, bid_id: bid, seller: seller}}
  end

  defp sides(_event, _indexed), do: :error

  defp amounts("0x" <> data) do
    case Base.decode16(data, case: :mixed) do
      {:ok, <<amount::256, premium::256, fee::256>>} ->
        {:ok,
         %{amount: Decimal.new(amount), premium: Decimal.new(premium), fee: Decimal.new(fee)}}

      _malformed ->
        :error
    end
  end

  defp amounts(_data), do: :error

  defp words(topics) do
    map_ok(topics, fn
      "0x" <> word when byte_size(word) == 64 ->
        with {:ok, <<value::256>>} <- Base.decode16(word, case: :mixed), do: {:ok, value}

      _malformed ->
        :error
    end)
  end

  # The other side of each sale, read from the contract at the head: a
  # listing's seller and a bid's bidder never change once made.
  defp counterparties(sales, market, head, opts) do
    listings = for %{event: :filled, listing_id: id} <- sales, uniq: true, do: id
    bids = for %{event: :sold_to_bid, bid_id: id} <- sales, uniq: true, do: id

    with {:ok, listings} <- Chain.records(market, :listing, listings, head, opts),
         {:ok, bids} <- Chain.records(market, :bid, bids, head, opts) do
      sellers = Map.new(listings, &{&1.id, &1.seller})
      bidders = Map.new(bids, &{&1.id, &1.bidder})

      {:ok,
       Enum.map(sales, fn
         %{event: :filled} = sale -> Map.put(sale, :seller, sellers[sale.listing_id])
         %{event: :sold_to_bid} = sale -> Map.put(sale, :buyer, bidders[sale.bid_id])
       end)}
    end
  end

  # The sales and the cursor's move commit together. A sale that differs from
  # its saved row stops the cursor at its block; a cursor another pass or an
  # operator moved first leaves this pass with nothing to add. An action that
  # fails rolls the whole transaction back with its own error, in whichever
  # form Ash gives it, so the errors are read through `Ash.Error.to_error_class/1`.
  defp commit(cursor, sales, to, head) do
    Repo.transaction(fn ->
      with :ok <- record(sales),
           {:ok, cursor} <-
             CoveredCalls.advance_covered_call_cursor(
               cursor,
               %{
                 from: cursor.next_block,
                 next_block: to + 1,
                 head_block: head.number,
                 head_block_hash: head.hash,
                 observed_at: DateTime.utc_now()
               },
               actor: @actor
             ) do
        cursor
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, cursor} -> {:ok, cursor}
      {:error, error} -> failed(cursor, error, Ash.Error.to_error_class(error).errors)
    end
  end

  defp failed(cursor, error, errors) do
    cond do
      block = Enum.find_value(errors, &(match?(%Diverged{}, &1) && &1.block)) ->
        stop(cursor, block)

      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        {:ok, :superseded}

      true ->
        {:error, error}
    end
  end

  defp record(sales) do
    Enum.reduce_while(sales, :ok, fn sale, :ok ->
      case CoveredCalls.record_covered_call_sale(sale, actor: @actor) do
        {:ok, _sale} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp stop(cursor, block) do
    CoveredCalls.stop_covered_call_cursor!(cursor, block, actor: @actor)
    {:stopped, block}
  end

  # After a committed pass: how far the chain's furthest-behind covered-call
  # cursor trails the head, and whether this contract has caught up.
  defp indexed({:ok, %Cursor{next_block: next}}, market, head) do
    least =
      Cursor
      |> Ash.Query.filter(chain_id == ^market.chain_id)
      |> Ash.min!(:next_block, actor: @actor)

    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: max(head.number - (least - 1), 0)},
      %{indexer: :covered_call_sales, chain_id: market.chain_id}
    )

    {:ok, if(next > head.number, do: :caught_up, else: :behind)}
  end

  defp indexed({:ok, :superseded}, _market, _head), do: {:ok, :behind}
  defp indexed(other, _market, _head), do: other

  defp quantity("0x" <> hex) when hex != "" do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> :error
    end
  end

  defp quantity(_value), do: :error

  defp map_ok(items, read) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, kept} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | kept]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end
end
