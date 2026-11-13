defmodule Autolaunch.CoveredCalls.Book do
  @moduledoc """
  Each covered-call market's open listings and bids, as its contract holds
  them at the latest block, shared by every visitor.

  A reading holds what the site offers, best first (`Terms.for_buyers/1`,
  `Terms.for_sellers/2`): the open listings and open bids on the expiries the
  site offers (`Terms.expiries/1`), at most fifty of each for each expiry, with
  the count of all of each (`listings_total`, `bids_total`). The contract takes
  any Friday a 64-bit time can hold, so one on another expiry is never offered.
  A listing or bid with less than one whole token left is dust and is not
  offered (`Terms.dust?/2`). Anyone with USDC can post bids, and anyone with a
  raw unit of the stock can list, so the cap is what keeps a page, an agent's
  answer and each visitor's copy of the reading small however many there are,
  and it is counted for each expiry so the nearest Friday never hides a later
  one.

  One reading per market is kept for five minutes (`:covered_calls_book_kept_ms`;
  0 keeps nothing, as the tests run); a landed press on the chain
  (`Autolaunch.ChainRefresh`) shortens that to ten seconds from when it was
  taken, so the next visit after a person acts reads again. A covered-call
  step that lands drops its market's reading at once (`expire/1`), so the page
  that sent it, and the portfolio, show what it changed; a reading being taken
  when it lands is handed to those already waiting and not kept.

  A reading is taken in a task under `Autolaunch.TaskSupervisor`, never inside
  this process: visitors who ask while it is being taken wait for that one
  reading instead of each starting their own, and this process stays free to
  answer for every other market and to drop a reading. A visitor waits at most
  fifteen seconds and is then told the chain could not be read; the reading goes
  on and is kept for the next visitor.

  Every listing and bid read, here or for a wallet's positions (`keep/2`), is
  kept in a table for as long as the site runs, with who made it and what of
  it can still change (`kept/3`): nothing once it is settled
  (`Terms.settled?/2`); only its seller's part once a listing has stopped or
  its window has closed; anything else. Who made a listing or bid and its
  expiry never change, so this reading reads one again only while it can
  change and its expiry is one the site offers: a bid past its expiry and
  never refunded, or one on a far Friday, is read once. A wallet's positions
  read again only what can change for that wallet
  (`Autolaunch.CoveredCalls.Positions`). The records are facts of the chain,
  so a dropped reading leaves them.

  A link to one listing or bid the reading does not offer reads that record on
  its own (`one/3`), shared and kept the same way: one task takes it while
  others wait, it is kept as long as the reading, a landed press shortens it
  the same, and dropping a market's reading drops its records too, so a
  ticket opened from a link is never older than the list. A kept record past
  its time is dropped when the next reading is kept.

  A reading never disables a button: a press is checked against the chain when
  its step is built (`Autolaunch.CoveredCalls.Steps`).
  """

  use GenServer

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.CoveredCalls.{Chain, Deployment, Quote, Terms}

  @read_timeout 15_000
  @shown 50
  @table __MODULE__

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The shared reading of `symbol`'s market, at most five minutes old. A reading
  that takes longer than fifteen seconds is `:chain_unavailable` to this caller.
  """
  @spec read(String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol) do
    GenServer.call(__MODULE__, {:read, symbol}, @read_timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :chain_unavailable}
  end

  @doc """
  Drops `symbol`'s reading, so the next read takes a new one. It never waits,
  even while a reading is being taken.
  """
  @spec expire(String.t()) :: :ok
  def expire(symbol), do: GenServer.cast(__MODULE__, {:expire, symbol})

  @impl Autolaunch.ChainRefresh
  def refresh(chain_id) do
    case Deployment.current() do
      {:ok, %{chain_id: ^chain_id}} -> GenServer.cast(__MODULE__, :refresh)
      _other_chain_or_off -> :ok
    end
  end

  @doc """
  `contract`'s listing or bid (`kind`) numbered `id` as last read: who made it,
  what of it can still change (`:settled`, nothing; `:closed`, a listing's
  seller's part only; `:live`, anything) and the record; nil until it is read.
  """
  def kept(contract, kind, id) do
    case :ets.lookup(@table, {contract, kind, id}) do
      [{_key, owner, state, record}] -> {owner, state, record}
      [] -> nil
    end
  end

  @doc "How many open listings, and how many open bids, a reading holds for each expiry."
  def shown, do: @shown

  @doc """
  `symbol`'s listing or bid (`kind`) numbered `id`, as its contract holds it
  at the latest block, with that block's time (`now`); `:unknown_listing` or
  `:unknown_bid` when the contract has none by that id. A link to one that is
  not in the reading opens it from here: one record, read on its own, shared
  and kept as the reading is, and kept like every other read (`keep/2`).
  """
  @spec one(String.t(), :listing | :bid, pos_integer()) :: {:ok, map()} | {:error, atom()}
  def one(symbol, kind, id) do
    GenServer.call(__MODULE__, {:read, {symbol, kind, id}}, @read_timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :chain_unavailable}
  end

  defp record(:listing, market, id, block, opts), do: Chain.listing(market, id, block, opts)
  defp record(:bid, market, id, block, opts), do: Chain.bid(market, id, block, opts)

  defp many(:listing), do: :listings
  defp many(:bid), do: :bids

  @doc "Keeps each listing and bid of `book` (`Chain.book/4`) as read at its block (`kept/3`)."
  def keep(contract, book) do
    if kept_ms() > 0 do
      :ets.insert(
        @table,
        for(
          {kind, owner, records} <- [
            {:listing, :seller, book.listings},
            {:bid, :bidder, book.bids}
          ],
          record <- records,
          do:
            {{contract, kind, record.id}, Map.fetch!(record, owner), state(record, book.now),
             record}
        )
      )
    end

    :ok
  end

  @doc "The settled listings or bids (`kind`) of `contract` that `wallet` made."
  def settled(contract, kind, wallet),
    do: :ets.select(@table, [{{{contract, kind, :_}, wallet, :settled, :"$1"}, [], [:"$1"]}])

  @doc """
  The kept listings of `contract` some of which was bought that `wallet`'s
  positions take as kept: the settled ones, and those of others that have
  stopped or whose window has closed, where nothing a holder has can change
  but by the holder's own claim.
  """
  def bought(contract, wallet) do
    :ets.select(@table, [
      {{{contract, :listing, :_}, :_, :settled, %{filled: :"$1"}}, [{:>, :"$1", 0}], [:"$_"]},
      {{{contract, :listing, :_}, :"$2", :closed, %{filled: :"$1"}},
       [{:>, :"$1", 0}, {:"=/=", :"$2", wallet}], [:"$_"]}
    ])
    |> Enum.map(&elem(&1, 3))
  end

  @doc """
  What the site offers of a market's `book` (`Chain.book/4`): its open
  listings and open bids on the expiries the site offers that are not dust,
  each best first and cut to the first fifty of each expiry, with the count of
  all of each.
  """
  def reading(book, market) do
    spot =
      case Quote.spot(book) do
        {:ok, spot} -> spot
        {:error, :price_unavailable} -> nil
      end

    offered = Terms.expiries(book.now)

    listings =
      book.listings
      |> Enum.filter(&(Terms.stage(&1, book.now) == :open and on_offer?(&1, offered, book.unit)))
      |> Enum.sort_by(&Terms.for_buyers/1)

    bids =
      book.bids
      |> Enum.filter(
        &(Terms.bid_stage(&1, book.now) == :open and on_offer?(&1, offered, book.unit))
      )
      |> Enum.sort_by(&Terms.for_sellers(&1, spot))

    Map.merge(book, %{
      market: market,
      read_at: DateTime.utc_now(),
      listings: shown(listings),
      listings_total: length(listings),
      bids: shown(bids),
      bids_total: length(bids)
    })
  end

  defp on_offer?(record, offered, unit),
    do: record.expiry in offered and not Terms.dust?(record, unit)

  # The best fifty of each expiry, from records in order of expiry first.
  defp shown(records),
    do: records |> Enum.chunk_by(& &1.expiry) |> Enum.flat_map(&Enum.take(&1, @shown))

  # `kept` is each market's reading, and each single record read for a link
  # (keyed `{symbol, kind, id}`), with when it was taken and until when it is
  # good; `taking` the task whose reading will be kept for each; and `waiting`
  # who each running task answers.
  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    {:ok, %{kept: %{}, taking: %{}, waiting: %{}}}
  end

  @impl GenServer
  # However many refreshes arrive, a reading stays good for ten seconds from
  # when it was taken, so a crowd asking at once costs one read.
  def handle_cast(:refresh, state) do
    gap = Autolaunch.ChainRefresh.gap_s() * 1_000

    kept =
      Map.new(state.kept, fn {symbol, {reading, taken_at, good_until}} ->
        {symbol, {reading, taken_at, min(good_until, taken_at + gap)}}
      end)

    {:noreply, %{state | kept: kept}}
  end

  # A reading being taken now may be from before the step landed: it still
  # answers those waiting for it, and the next read starts another.
  def handle_cast({:expire, symbol}, state) do
    {:noreply,
     %{state | kept: drop_market(state.kept, symbol), taking: drop_market(state.taking, symbol)}}
  end

  defp drop_market(readings, symbol),
    do: Map.reject(readings, fn {key, _value} -> market(key) == symbol end)

  defp market({symbol, _kind, _id}), do: symbol
  defp market(symbol), do: symbol

  @impl GenServer
  def handle_call({:read, key}, from, state) do
    case state.kept do
      %{^key => {reading, _taken_at, good_until}} ->
        if good_until > now(),
          do: {:reply, {:ok, reading}, state},
          else: {:noreply, wait(state, key, from)}

      _none ->
        {:noreply, wait(state, key, from)}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_map_key(state.waiting, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, taken(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.waiting, ref),
      do: {:noreply, taken(state, ref, {:error, :chain_unavailable})}

  def handle_info(_other, state), do: {:noreply, state}

  defp wait(state, key, from) do
    ref =
      state.taking[key] ||
        Task.Supervisor.async_nolink(Autolaunch.TaskSupervisor, fn -> take(key) end).ref

    %{
      state
      | taking: Map.put(state.taking, key, ref),
        waiting: Map.update(state.waiting, ref, [from], &[from | &1])
    }
  end

  # A task's reading answers everyone waiting for it, and is kept when it is
  # still the one its market or record is taking; keeping one drops those past
  # their time.
  defp taken(state, ref, result) do
    {waiting, others} = Map.pop(state.waiting, ref)
    key = Enum.find_value(state.taking, fn {key, taking} -> taking == ref && key end)
    kept_ms = kept_ms()

    {answer, kept} =
      case result do
        {:ok, reading} ->
          taken_at = now()

          {{:ok, reading},
           if(key,
             do:
               state.kept
               |> Map.reject(fn {_key, {_reading, _taken_at, good_until}} ->
                 good_until <= taken_at
               end)
               |> Map.put(key, {reading, taken_at, taken_at + kept_ms}),
             else: state.kept
           )}

        {:error, _reason} = error ->
          {error, state.kept}
      end

    Enum.each(waiting, &GenServer.reply(&1, answer))
    %{state | kept: kept, taking: Map.delete(state.taking, key), waiting: others}
  end

  defp take({symbol, kind, id}) do
    with {:ok, config} <- Deployment.current(),
         {:ok, %{contract: contract} = market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, record} <- record(kind, market, id, block, opts) do
      keep(
        contract,
        Map.put(%{listings: [], bids: [], now: block.timestamp}, many(kind), [record])
      )

      {:ok, %{record: record, now: block.timestamp}}
    end
  end

  defp take(symbol) do
    with {:ok, config} <- Deployment.current(),
         {:ok, %{contract: contract} = market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         offered = Terms.expiries(block.timestamp),
         {:ok, book} <- Chain.book(market, block, opts, &read_again?(contract, offered, &1, &2)) do
      keep(contract, book)
      {:ok, reading(book, market)}
    end
  end

  # A listing or bid is read the first time, then again only while it can
  # change and its expiry is offered: only then can it be in a reading.
  defp read_again?(contract, offered, kind, id) do
    case kept(contract, kind, id) do
      nil -> true
      {_owner, state, record} -> state == :live and record.expiry in offered
    end
  end

  # What of a listing or bid read at `now` can still change: nothing once it
  # is settled; for a listing that stopped or whose window has closed, only
  # its seller's part (stock to take back, strike to collect); else anything.
  defp state(record, now) do
    cond do
      Terms.settled?(record, now) -> :settled
      match?(%{seller: _}, record) and Terms.stage(record, now) in [:stopped, :closed] -> :closed
      true -> :live
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp kept_ms, do: Application.get_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
end
