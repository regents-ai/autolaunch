defmodule Autolaunch.MarketReadings do
  @moduledoc """
  The market feeds' readings in `Autolaunch.SharedReading`: what a feed stores
  after each pass, and what a page reads back. Each feed is the one producer of
  its own keys; a page subscribes to a key (`Autolaunch.SharedReading.subscribe/1`),
  reads it here, and reads it again on each `{:shared_reading, key}`.

    * `feed_key/1` — held while the feed (`"base"`, `"stocks"` or
      `"robinhood"`) last read its chain, marked degraded while it could not
      (`stale?/1`).
    * `head_key/1` — the newest block the feed stored readings at (`head/1`):
      the clock of a page that draws time passing.
    * `market_key/1` — one auction's figures, by its address (`market/1`).
    * `page_key/1` — everything one auction's own page shows from the chain,
      at one block (`page/1`).

  A page is told of a key only when its reading changed, so a page showing one
  auction hears nothing of the others, and nothing of its own while its
  figures stay as they are.
  """

  alias Autolaunch.SharedReading

  # What a feed's reading carries for its own writes, not for a page.
  @feed_only [:positions, :page]
  # The block a reading was read at, and the block its auction kept time by.
  @read_at [:block, :block_number, :block_hash, :clock]
  @feeds %{agent: "base", stocks: "stocks"}
  @start_wait 2_000

  def feed_key(feed) when feed in ["base", "stocks", "robinhood"], do: {:market_feed, feed}
  def head_key(feed) when feed in ["base", "stocks", "robinhood"], do: {:market_head, feed}
  def market_key(address) when is_binary(address), do: {:auction_market, String.downcase(address)}
  def page_key(address) when is_binary(address), do: {:auction_page, String.downcase(address)}

  @doc "The feed that reads a Base auction of `kind`."
  @spec feed(:agent | :stocks) :: String.t()
  def feed(kind), do: Map.fetch!(@feeds, kind)

  @doc "Whether `feed` could not read its chain on its last pass."
  @spec stale?(String.t()) :: boolean()
  def stale?(feed), do: match?({:ok, %{degraded?: true}}, SharedReading.fetch(feed_key(feed)))

  @doc "Whether `feed` has answered since the site started: it read its chain, or could not."
  @spec running?(String.t()) :: boolean()
  def running?(feed), do: SharedReading.fetch(feed_key(feed)) != :error

  @doc "The newest block `feed` stored readings at, or nil before its first."
  @spec head(String.t()) :: map() | nil
  def head(feed), do: reading(head_key(feed))

  @doc "The figures of the auction at `address`, or nil while it has no reading."
  @spec market(String.t() | nil) :: map() | nil
  def market(address) when is_binary(address), do: reading(market_key(address))
  def market(_address), do: nil

  @doc """
  What the page of the auction at `address` shows from the chain: the reading
  and whether the feed's last attempt at it failed, or `:error` while there is
  none.
  """
  @spec page(String.t()) :: {:ok, %{reading: map() | nil, degraded?: boolean()}} | :error
  def page(address), do: SharedReading.fetch(page_key(address))

  defp reading(key) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: reading}} -> reading
      :error -> nil
    end
  end

  @doc """
  Stores one pass's readings: each auction's first, then `head`, the block the
  pass read at, so a page woken by the head finds every reading of the pass. A
  reading whose `page` could not be read keeps the page's last one, marked
  degraded; so does a reading the store refuses (`SharedReading.put/2`), which
  would otherwise stay on show as though it were this pass's.

  Each reading names the block it was read at. One whose figures match the
  reading already held keeps the held one's block, so a page is woken when a
  figure it shows changes and not because a block went by.
  """
  @spec store(String.t(), map(), [map()]) :: :ok
  def store(feed, head, readings) do
    for %{auction_address: address} = reading <- readings do
      put_changed(market_key(address), Map.drop(reading, @feed_only))

      case reading do
        %{page: {:ok, page}} -> put_changed(page_key(address), page)
        %{page: :error} -> SharedReading.degraded(page_key(address))
        _no_page -> :ok
      end
    end

    put(head_key(feed), head)
    :ok
  end

  defp put_changed(key, reading) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: %{} = held}} ->
        if Map.drop(held, @read_at) == Map.drop(reading, @read_at),
          do: put(key, held),
          else: put(key, reading)

      _none ->
        put(key, reading)
    end
  end

  defp put(key, reading) do
    with {:error, _refused} <- SharedReading.put(key, reading), do: SharedReading.degraded(key)
  end

  @doc """
  Marks the figures and the page of the auction at `address` as not read this
  pass: the feed could not read the auction, or ran out of time on it. Their
  last readings stay, marked degraded.
  """
  @spec unread_auction(String.t()) :: :ok
  def unread_auction(address) do
    SharedReading.degraded(market_key(address))
    SharedReading.degraded(page_key(address))
    :ok
  end

  @doc "The addresses a feed holds readings for, after a pass added `readings`."
  @spec held(MapSet.t(), [map()]) :: MapSet.t()
  def held(held, readings), do: Enum.into(readings, held, & &1.auction_address)

  @doc "Forgets every reading of the auctions at `addresses`: the chain left the block they were read at."
  @spec forget(Enumerable.t()) :: :ok
  def forget(addresses) do
    for address <- addresses do
      SharedReading.delete(market_key(address))
      SharedReading.delete(page_key(address))
    end

    :ok
  end

  @doc """
  A feed's first word, given inside its own start: whether `head`, which reads
  its chain's newest block, answered within two seconds. So the site begins
  serving with every feed answered one way or the other, and a provider being
  down never keeps it from starting.
  """
  @spec start(String.t(), (-> {:ok, term()} | {:error, term()})) :: :ok
  def start(feed, head) do
    task = Task.Supervisor.async_nolink(Autolaunch.TaskSupervisor, head)

    case Task.yield(task, @start_wait) || Task.shutdown(task) do
      {:ok, {:ok, _head}} -> read(feed)
      _unread -> unread(feed)
    end

    :ok
  end

  @doc "Marks that `feed`'s last pass read its chain."
  def read(feed), do: SharedReading.put(feed_key(feed), :read)

  @doc "Marks that `feed`'s last pass could not read its chain."
  def unread(feed), do: SharedReading.degraded(feed_key(feed))
end
