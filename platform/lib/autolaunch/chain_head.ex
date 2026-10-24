defmodule Autolaunch.ChainHead do
  @moduledoc """
  The newest block of each auction deployment, read once for every open page
  and held in `Autolaunch.SharedReading` under `key/1`: the block number for
  Base Revstake (`"base"`) and Base Memestock (`"stocks"`), and the rollup
  clock the Robinhood contracts keep time by (`"robinhood"`,
  `Autolaunch.Robinhood.BlockClock`). It is the clock a page draws time passing
  by; a key marked degraded says the site could not read that chain on its last
  attempt. One runs for each configured deployment on each machine that serves
  pages: every second on a lab, every five minutes on mainnet, and within ten
  seconds of a person's on-chain press landing on its chain (`refresh/1`, from
  `Autolaunch.ChainRefresh`).

  This is ash-template's `AshTemplate.ChainHead`, a supervised reader of an
  outside clock, one of the two shapes the `elixir-stack` skill lets reread on
  their own. Nothing here is work that could be lost: it holds no queue and no
  copy of database rows, never writes the database, and stores only through
  `SharedReading`; a read that fails is not tried again, because the next one
  replaces it.

  The first read happens as the reader starts, so the key holds a reading or
  its degraded mark before the site serves a page. Each later read is scheduled
  only when the last has finished, so reads never pile up behind a slow node.
  """

  use GenServer

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.{ChainRefresh, Lab, SharedReading}
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Robinhood.BlockClock
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @lab_every_ms 1_000
  @mainnet_every_ms 300_000

  @doc "One reader for each auction deployment this site describes."
  def children do
    for {feed, every_ms} <- configured() do
      Supervisor.child_spec({__MODULE__, {feed, every_ms}}, id: {__MODULE__, feed})
    end
  end

  defp configured do
    [
      {"base", match?({:ok, _config}, Lab.current()), Lab.test_chain?()},
      {"stocks", match?({:ok, _config}, StocksLab.current()), Lab.test_chain?()},
      {"robinhood", RobinhoodLab.configured?(), RobinhoodLab.test_chain?()}
    ]
    |> Enum.filter(fn {_feed, configured?, _lab?} -> configured? end)
    |> Enum.map(fn {feed, _configured?, lab?} ->
      {feed, if(lab?, do: @lab_every_ms, else: @mainnet_every_ms)}
    end)
  end

  @doc "Where the newest block of deployment `feed` is held."
  def key(feed) when feed in ["base", "stocks", "robinhood"], do: {:chain_head, feed}

  @doc """
  The newest block of `feed` and whether its last read failed, or nil while it
  has never been read.
  """
  @spec fetch(String.t()) :: %{block: non_neg_integer() | nil, degraded?: boolean()} | nil
  def fetch(feed) do
    case SharedReading.fetch(key(feed)) do
      {:ok, %{reading: block, degraded?: degraded?}} -> %{block: block, degraded?: degraded?}
      :error -> nil
    end
  end

  @doc "Whether the site could not read `feed`'s chain on its last attempt."
  @spec stale?(String.t()) :: boolean()
  def stale?(feed), do: match?(%{degraded?: true}, fetch(feed))

  @doc "Reads every deployment on chain `chain_id` again soon, on every machine."
  @impl ChainRefresh
  def refresh(chain_id) do
    for {feed, _every_ms} <- configured(),
        chain_id(feed) == chain_id,
        do: Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(feed), :chain_refresh)

    :ok
  end

  defp chain_id("base"), do: Lab.chain_id()
  defp chain_id("stocks"), do: Lab.chain_id()
  defp chain_id("robinhood"), do: RobinhoodLab.chain_id()

  defp topic(feed), do: "chain_head:#{feed}"

  def start_link({feed, every_ms}) when is_binary(feed) and every_ms >= 1_000,
    do: GenServer.start_link(__MODULE__, {feed, every_ms})

  @impl true
  def init({feed, every_ms}) do
    :ok = Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(feed))
    {:ok, read(%{feed: feed, every_ms: every_ms, read_at: nil, timer: nil})}
  end

  @impl true
  def handle_info(:read, head), do: {:noreply, read(head)}

  # A press landed: read again once ten seconds have passed since the last
  # read began, unless the next read is due sooner.
  def handle_info(:chain_refresh, head) do
    wait = max(head.read_at + ChainRefresh.gap_s() * 1_000 - now(), 0)

    case Process.read_timer(head.timer) do
      left when is_integer(left) and left > wait ->
        Process.cancel_timer(head.timer)
        {:noreply, %{head | timer: Process.send_after(self(), :read, wait)}}

      _sooner ->
        {:noreply, head}
    end
  end

  defp read(%{feed: feed} = head) do
    read_at = now()

    case newest(feed) do
      {:ok, block} -> SharedReading.put(key(feed), block)
      {:error, _reason} -> SharedReading.degraded(key(feed))
    end

    %{head | read_at: read_at, timer: Process.send_after(self(), :read, head.every_ms)}
  end

  defp newest("base") do
    with {:ok, config} <- Lab.current(),
         {:ok, block} <- Rpc.latest_block(Lab.rpc_opts(config, "chain head")),
         do: {:ok, block.number}
  end

  defp newest("stocks") do
    with {:ok, config} <- StocksLab.current(),
         {:ok, block} <- Rpc.latest_block(StocksLab.rpc_opts(config, "chain head")),
         do: {:ok, block.number}
  end

  defp newest("robinhood") do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         do: BlockClock.read(block, opts)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
