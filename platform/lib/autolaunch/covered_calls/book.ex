defmodule Autolaunch.CoveredCalls.Book do
  @moduledoc """
  Each covered-call market's open listings and bids, as its contract holds
  them at the latest block, shared by every visitor.

  A reading holds what the site offers, best first (`Terms.for_buyers/1`,
  `Terms.for_sellers/2`): at most fifty open listings and fifty open bids, each
  with the count of all that are open (`listings_total`, `bids_total`). A bid
  with less than one whole token left is dust and is not offered
  (`Terms.dust?/2`). Anyone with USDC can post bids, so the cap is what keeps
  a page, an agent's answer and each visitor's copy of the reading small
  however many there are.

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

  Listings and bids that can never change again (`Terms.settled?/2`) are kept
  in a table for as long as the site runs and never read again, by this
  reading or by a wallet's positions (`settled?/3`, `settled/3`). They are
  facts of the chain, so a dropped reading leaves them.

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

  @doc "Whether `contract`'s listing or bid (`kind`) numbered `id` is kept as settled."
  def settled?(contract, kind, id), do: :ets.member(@table, {contract, kind, id})

  @doc """
  The settled listings or bids (`kind`) of `contract` that `wallet` made, or
  with `:exercised` the settled listings some of which was exercised: the only
  settled ones a holder can still have stock to claim on.
  """
  def settled(contract, kind, wallet) when is_binary(wallet),
    do: :ets.select(@table, [{{{contract, kind, :_}, wallet, :"$1"}, [], [:"$1"]}])

  def settled(contract, :listing, :exercised) do
    :ets.select(@table, [
      {{{contract, :listing, :_}, :_, %{exercised: :"$1"}}, [{:>, :"$1", 0}], [:"$_"]}
    ])
    |> Enum.map(&elem(&1, 2))
  end

  @doc """
  What the site offers of a market's `book` (`Chain.book/4`): its open
  listings and its open bids that are not dust, each best first and cut to the
  first fifty, with the count of all of each.
  """
  def reading(book, market) do
    spot =
      case Quote.spot(book) do
        {:ok, spot} -> spot
        {:error, :price_unavailable} -> nil
      end

    listings =
      book.listings
      |> Enum.filter(&(Terms.stage(&1, book.now) == :open))
      |> Enum.sort_by(&Terms.for_buyers/1)

    bids =
      book.bids
      |> Enum.filter(&(Terms.bid_stage(&1, book.now) == :open and not Terms.dust?(&1, book.unit)))
      |> Enum.sort_by(&Terms.for_sellers(&1, spot))

    Map.merge(book, %{
      market: market,
      read_at: DateTime.utc_now(),
      listings: Enum.take(listings, @shown),
      listings_total: length(listings),
      bids: Enum.take(bids, @shown),
      bids_total: length(bids)
    })
  end

  # `kept` is each market's reading with when it was taken and until when it
  # is good; `taking` the task whose reading will be kept for a market; and
  # `waiting` who each running task answers.
  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :ordered_set, :protected, read_concurrency: true])
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
     %{state | kept: Map.delete(state.kept, symbol), taking: Map.delete(state.taking, symbol)}}
  end

  @impl GenServer
  def handle_call({:read, symbol}, from, state) do
    case state.kept do
      %{^symbol => {reading, _taken_at, good_until}} ->
        if good_until > now(),
          do: {:reply, {:ok, reading}, state},
          else: {:noreply, wait(state, symbol, from)}

      _none ->
        {:noreply, wait(state, symbol, from)}
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

  defp wait(state, symbol, from) do
    ref =
      state.taking[symbol] ||
        Task.Supervisor.async_nolink(Autolaunch.TaskSupervisor, fn -> take(symbol) end).ref

    %{
      state
      | taking: Map.put(state.taking, symbol, ref),
        waiting: Map.update(state.waiting, ref, [from], &[from | &1])
    }
  end

  # A task's reading answers everyone waiting for it, and is kept when it is
  # still the one its market is taking.
  defp taken(state, ref, result) do
    {waiting, others} = Map.pop(state.waiting, ref)
    symbol = Enum.find_value(state.taking, fn {symbol, taking} -> taking == ref && symbol end)
    kept_ms = kept_ms()

    {answer, kept} =
      case result do
        {:ok, reading, settled} ->
          if kept_ms > 0, do: :ets.insert(@table, settled)
          taken_at = now()

          {{:ok, reading},
           if(symbol,
             do: Map.put(state.kept, symbol, {reading, taken_at, taken_at + kept_ms}),
             else: state.kept
           )}

        {:error, _reason} = error ->
          {error, state.kept}
      end

    Enum.each(waiting, &GenServer.reply(&1, answer))
    %{state | kept: kept, taking: Map.delete(state.taking, symbol), waiting: others}
  end

  defp take(symbol) do
    with {:ok, config} <- Deployment.current(),
         {:ok, market} <- Deployment.market(symbol),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, book} <- Chain.book(market, block, opts, &settled?(market.contract, &1, &2)) do
      {:ok, reading(book, market), settled_rows(book, market.contract)}
    end
  end

  # A table row for each record that can never change again: its contract,
  # kind and id, who made it, and the record.
  defp settled_rows(book, contract) do
    for(
      {kind, owner, records} <- [{:listing, :seller, book.listings}, {:bid, :bidder, book.bids}],
      record <- records,
      Terms.settled?(record, book.now),
      do: {{contract, kind, record.id}, Map.fetch!(record, owner), record}
    )
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp kept_ms, do: Application.get_env(:autolaunch, :covered_calls_book_kept_ms, 300_000)
end
