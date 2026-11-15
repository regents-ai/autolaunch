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
  it already read (ten minutes of Base) and the new ones after them, and saves
  the new sales and moves the cursor in one transaction. The cursor moves only
  from where the pass found it, so of two passes that overlap only the first
  saves; the other reads again a second later.

  A transaction's sales are saved by the first pass that reads it and kept as
  first saved: wherever the chain puts that transaction later, nothing from it
  is saved or offered again. Each saved transaction is checked once, by the
  pass that reads its block for the last time (the one whose search ends 300
  blocks or more after it). If its sales then no longer match the saved ones
  (moved to another block, in a block whose hash changed, changed, or gone),
  that is one warning line naming the contract and the transaction, and the
  pass carries on: the saved sales stay, with what they earned. A log that does
  not read as a sale is skipped with one warning, when its block is first read.

  The job then waits a second while the contract is behind the head and five
  minutes once it has caught up. A node that does not answer, or answers with
  something that is not what was asked, is one warning line and a minute's
  wait, with nothing saved. Every pass that read the head reports how far the
  chain's covered-call cursors trail it, committed or not, so a reader held up
  by its node shows a lag that grows. It does nothing while covered calls are
  off or their contracts are not described.
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
  alias Autolaunch.CoveredCalls.{Chain, Cursor, Deployment}
  alias Autolaunch.Repo
  alias RegentChain.{Address, Event}

  @actor %System{}
  @reread 300
  @stretch 10_000
  @events %{
    "Filled(uint256,address,uint256,uint256,uint256)" => :filled,
    "SoldToBid(uint256,uint256,address,uint256,uint256,uint256)" => :sold_to_bid
  }
  # The node did not answer, answered with something that is not what was
  # asked, or answered for a block that has since moved.
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
         {:ok, head, opts} <- Chain.latest(lab) do
      result =
        with {:ok, cursor} <- opened(cursor, market, head, opts),
             do: pass(cursor, market, head, opts)

      lag(market, head)
      result
    end
  end

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
         {read, unread} = decode(logs, market, topics, cursor.next_block),
         {:ok, headers} <- headers(read, opts),
         {:ok, read} <- map_ok(read, &placed(&1, headers)),
         {:ok, saved} <-
           CoveredCalls.seen_covered_call_sales(
             market.chain_id,
             market.contract,
             from,
             cursor.next_block - 1,
             read |> Enum.map(& &1.transaction_hash) |> Enum.uniq(),
             actor: @actor
           ),
         {fresh, moved} = compare(read, saved, from, to - @reread),
         {:ok, fresh} <- counterparties(fresh, market, head, opts),
         {:ok, cursor} <- commit(cursor, fresh, to, head) do
      Enum.each(unread, &Logger.warning/1)

      for transaction <- moved,
          do:
            Logger.warning(
              "Covered-call sales on #{market.contract} in transaction #{transaction} " <>
                "no longer match the chain; the sales saved first are kept"
            )

      {:ok, if(cursor.next_block > head.number, do: :caught_up, else: :behind)}
    else
      :superseded -> {:ok, :behind}
      {:error, reason} -> {:error, reason}
    end
  end

  # The logs that read as sales, and a warning for each one that does not,
  # given only when its block is first read: one in the 300 blocks read again
  # was named by the pass that first read it.
  defp decode(logs, market, topics, next) do
    decoded = Enum.map(logs, &{&1, decoded(&1, market, topics)})
    sales = for {_log, {:ok, sale}} <- decoded, do: sale

    unread =
      for {log, :error} <- decoded,
          new?(log, next),
          do:
            "Covered-call log on #{market.contract} in transaction #{transaction(log)} " <>
              "skipped: it does not read as a sale"

    {sales, unread}
  end

  defp new?(%{"blockNumber" => number}, next) do
    case quantity(number) do
      {:ok, block} -> block >= next
      :error -> true
    end
  end

  defp new?(_log, _next), do: true

  defp transaction(%{"transactionHash" => hash}) when is_binary(hash), do: hash
  defp transaction(_log), do: "unknown"

  # The blocks the sales were read in.
  defp headers(sales, opts) do
    sales
    |> Enum.map(& &1.block_number)
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
         {:ok, seconds} <- quantity(timestamp),
         {:ok, at} <- DateTime.from_unix(seconds) do
      {:ok, {number, %{hash: String.downcase(hash), at: at}}}
    else
      _unavailable -> {:error, :header_unavailable}
    end
  end

  # A sale in its block as the pass read it. A log from another block than
  # the one read under its number is from a chain that has since moved, and
  # the pass is read again.
  defp placed(sale, headers) do
    %{hash: hash, at: at} = headers[sale.block_number]

    if sale.block_hash == hash,
      do: {:ok, Map.put(sale, :occurred_at, at)},
      else: {:error, :head_moved}
  end

  # The sales of transactions not saved yet, and each saved transaction this
  # pass reads for the last time (in a block from `from` to `last`, which the
  # next pass's search starts after) whose sales read now no longer match the
  # saved ones. A transaction's sales are all in one block.
  defp compare(read, saved, from, last) do
    saved = Enum.group_by(saved, & &1.transaction_hash)
    read_now = Enum.group_by(read, & &1.transaction_hash)
    fresh = Enum.reject(read, &Map.has_key?(saved, &1.transaction_hash))

    moved =
      for {transaction, [%{block_number: block} | _] = rows} <- saved,
          from <= block and block <= last,
          facts(rows) != facts(Map.get(read_now, transaction, [])),
          do: transaction

    {fresh, Enum.sort(moved)}
  end

  # What a sale's log says, the side read from the contract left out.
  defp facts(sales) do
    sales
    |> Enum.map(fn sale ->
      {sale.log_index, sale.block_number, sale.block_hash, sale.event, sale.listing_id,
       sale.bid_id, named(sale), Decimal.to_integer(sale.amount),
       Decimal.to_integer(sale.premium), Decimal.to_integer(sale.fee)}
    end)
    |> Enum.sort()
  end

  defp named(%{event: :filled, buyer: buyer}), do: buyer
  defp named(%{event: :sold_to_bid, seller: seller}), do: seller

  defp decoded(%{} = log, market, topics) do
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
         block_number: number,
         block_hash: String.downcase(log["blockHash"])
       }
       |> Map.merge(sides)
       |> Map.merge(amounts)}
    else
      _malformed -> :error
    end
  end

  defp decoded(_log, _market, _topics), do: :error

  # `Filled(listingId, buyer)` names the buyer; `SoldToBid(bidId, listingId,
  # seller)` the seller. Listings and bids count from 1.
  defp sides(:filled, [listing, buyer]) do
    with {:ok, [listing, buyer]} <- words([listing, buyer]),
         true <- listing > 0,
         {:ok, buyer} <- Event.address(buyer),
         do: {:ok, %{listing_id: listing, bid_id: nil, buyer: buyer}}
  end

  defp sides(:sold_to_bid, [bid, listing, seller]) do
    with {:ok, [bid, listing, seller]} <- words([bid, listing, seller]),
         true <- bid > 0 and listing > 0,
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

  # The new sales and the cursor's move commit together. A cursor another pass
  # moved first leaves this pass with nothing to add. An action that fails
  # rolls the whole transaction back with its own error, in whichever form Ash
  # gives it, so the errors are read through `Ash.Error.to_error_class/1`.
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
      {:ok, cursor} ->
        {:ok, cursor}

      {:error, error} ->
        if Enum.any?(
             Ash.Error.to_error_class(error).errors,
             &match?(%Ash.Error.Changes.StaleRecord{}, &1)
           ),
           do: :superseded,
           else: {:error, error}
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

  # How far the chain's furthest-behind covered-call cursor trails the head,
  # after every pass that read the head, whether it saved or not. None before
  # any cursor on the chain is open.
  defp lag(market, head) do
    least =
      Cursor
      |> Ash.Query.filter(chain_id == ^market.chain_id)
      |> Ash.min!(:next_block, actor: @actor)

    if least,
      do:
        :telemetry.execute(
          [:autolaunch, :indexer, :lag],
          %{blocks: max(head.number - (least - 1), 0)},
          %{indexer: :covered_call_sales, chain_id: market.chain_id}
        )
  end

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
