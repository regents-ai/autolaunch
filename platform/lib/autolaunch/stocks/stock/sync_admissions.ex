defmodule Autolaunch.Stocks.Stock.SyncAdmissions do
  @moduledoc """
  Writes what each stock launchpad says of its stocks at the latest block.

  For each stock launchpad the loaded descriptions name (Base Memestock and
  Robinhood Memestock, the launchpads new launches go through), in two passes:

  1. Every stock already saved for the chain is asked of the chain again, so
     a revoked stock leaves the list and a changed route or feed is taken up
     within one run. This pass is a handful of reads and comes first for every
     launchpad, so the saved stocks are right seconds after a server starts.
  2. The launchpad's `StockAdmitted` logs are read from where the last run
     stopped (`Autolaunch.Stocks.AdmissionScan`), less 1,000 blocks so a log
     that a reorganised block moved is read again, in ranges of 2,000 blocks
     (the range the site's other log readers use on both chains), at most 250
     ranges a run and none once the run is three minutes old. A launchpad
     never read before is read from the block its code first appears in.
     Every stock those logs name that is not saved yet is asked of the chain.
     The block after the last range read is then saved, with the stocks named
     but not read yet, so a failed range is read again and an unread stock is
     asked about again on every run, without reading its logs twice.

  Asking the chain of a stock means, at the latest block: the launchpad's
  `stockAdmission` for whether it is admitted, its decimals and its route; the
  route's `feed()`; the token's `name()` and `symbol()`. An answer that
  differs from the saved row is written. A saved stock this launchpad has
  never admitted is marked not admitted and keeps its other facts. One stock
  that cannot be read or saved does not hold back the others or the place in
  the logs: each is written on its own, and the run fails after them so it is
  tried again and seen for as long as that stock stays unread.

  A run is bounded: every chain call gives up after eight seconds, a stock's
  four reads after a minute, and the log read after three minutes, so a run
  ends well inside the twenty minutes after which a running job is taken for
  an orphan. One run at a time across every server: the job is unique while
  it waits, runs or waits to be tried again (`Autolaunch.Stocks.Stock`).

  The logs only say which addresses to ask about; no fact in a row comes from
  a log. Every route a launchpad admits has to name its price feed with
  `feed()`, the zero address for none (a local chain's practice routes). A
  route that does not answer fails the run, loudly, rather than being saved as
  a stock with no price.

  Nothing here signs or sends a transaction.
  """

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.Assets

  require Logger

  @admitted %{
    base_memestock: "StockAdmitted(address,uint8)",
    robinhood_memestock: "StockAdmitted(address,uint8,address)"
  }
  @range_blocks 2_000
  @ranges_per_run 250
  @reorg_margin 1_000
  @log_read_ms :timer.minutes(3)
  @facts [:symbol, :name, :decimals, :route, :feed, :admitted]
  @actor %Autolaunch.Actors.System{}

  def run do
    stop_logs_at = System.monotonic_time(:millisecond) + @log_read_ms
    pads = Enum.filter(Launchpads.configured(), &is_map_key(@admitted, &1.launchpad))

    Enum.find(
      Enum.map(pads, &refresh_saved/1) ++ Enum.map(pads, &read_admitted(&1, stop_logs_at)),
      :ok,
      &match?({:error, _reason}, &1)
    )
  end

  defp refresh_saved(pad) do
    with {:ok, head} <- Rpc.latest_block(pad.opts),
         {:ok, saved} <- saved(pad) do
      {_unread, recorded} = record(pad, head, saved, Map.keys(saved))
      recorded
    end
  end

  defp read_admitted(pad, stop_logs_at) do
    with {:ok, head} <- Rpc.latest_block(pad.opts),
         {:ok, scan} <-
           Autolaunch.stock_admission_scan(pad.chain_id, pad.contract, pad.run_id, actor: @actor),
         {:ok, first} <- first_block(scan, pad, head),
         last = min(first + @range_blocks * @ranges_per_run - 1, head.number),
         {logged, next_block, read} = logged_stocks(pad, first, last, stop_logs_at),
         {:ok, saved} <- saved(pad),
         named = Enum.reject(MapSet.union(logged, unread(scan)), &is_map_key(saved, &1)),
         {unread, recorded} = record(pad, head, saved, named),
         {:ok, _scan} <-
           Autolaunch.advance_stock_admission_scan(
             %{
               chain_id: pad.chain_id,
               launchpad: pad.contract,
               run_id: pad.run_id,
               next_block: reached(scan, next_block),
               unread: unread
             },
             actor: @actor
           ) do
      with :ok <- read, do: recorded
    end
  end

  defp unread(nil), do: MapSet.new()
  defp unread(scan), do: MapSet.new(scan.unread)

  # The saved place never moves back: a run that read no range keeps it.
  defp reached(nil, next_block), do: next_block
  defp reached(scan, next_block), do: max(scan.next_block, next_block)

  # The chain's saved stocks, by address.
  defp saved(pad) do
    with {:ok, stocks} <- Autolaunch.chain_stocks(Assets.stock_chain_id(pad), actor: @actor) do
      {:ok, Map.new(stocks, &{&1.address, &1})}
    end
  end

  defp first_block(nil, pad, head), do: Rpc.deployment_block(pad.contract, head.number, pad.opts)

  defp first_block(scan, _pad, head),
    do: {:ok, (scan.next_block - @reorg_margin) |> max(0) |> min(head.number)}

  # The stocks the logs name from `first` on, the first block not read, and
  # the failure that stopped the read short, if one did. The read also stops,
  # without failing, once the run's time for logs is spent.
  defp logged_stocks(pad, first, last, stop_logs_at) do
    first
    |> Stream.iterate(&(&1 + @range_blocks))
    |> Stream.take_while(&(&1 <= last))
    |> Enum.reduce_while({MapSet.new(), first, :ok}, fn from, {stocks, _next_block, :ok} ->
      to = min(from + @range_blocks - 1, last)

      with true <- System.monotonic_time(:millisecond) < stop_logs_at,
           {:ok, found} <- range_stocks(pad, from, to) do
        {:cont, {MapSet.union(stocks, found), to + 1, :ok}}
      else
        false -> {:halt, {stocks, from, :ok}}
        {:error, reason} -> {:halt, {stocks, from, {:error, reason}}}
      end
    end)
  end

  defp range_stocks(pad, from, to) do
    filter = %{
      address: pad.contract,
      fromBlock: quantity(from),
      toBlock: quantity(to),
      topics: [Abi.topic0(Map.fetch!(@admitted, pad.launchpad))]
    }

    case Rpc.request("eth_getLogs", [filter], pad.opts) do
      {:ok, logs} when is_list(logs) -> named_stocks(logs)
      {:ok, _answer} -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp named_stocks(logs) do
    Enum.reduce_while(logs, {:ok, MapSet.new()}, fn log, {:ok, stocks} ->
      case named_stock(log) do
        {:ok, stock} -> {:cont, {:ok, MapSet.put(stocks, stock)}}
        :error -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
  end

  # The stock is the event's first indexed word on both launchpads.
  defp named_stock(%{"topics" => [_event, "0x" <> word | _indexed]}) when byte_size(word) == 64 do
    case Integer.parse(word, 16) do
      {value, ""} -> Abi.word_address(value)
      _malformed -> :error
    end
  end

  defp named_stock(_log), do: :error

  # Asks the chain of each stock and writes what differs. Answers the stocks
  # that could not be read or saved and, if there were any, the first failure,
  # once every other stock has been written.
  defp record(pad, head, saved, stocks) do
    chain_id = Assets.stock_chain_id(pad)

    results =
      stocks
      |> Task.async_stream(&{&1, admission(pad, &1, head)},
        max_concurrency: 4,
        ordered: false,
        timeout: 60_000,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.map(fn
        {:ok, {stock, {:ok, admission}}} ->
          {stock, write(chain_id, stock, saved[stock], admission)}

        {:ok, {stock, {:error, reason}}} ->
          {stock, {:error, reason}}

        {:exit, {stock, _reason}} ->
          {stock, {:error, :chain_unavailable}}
      end)

    if Enum.any?(results, &match?({_stock, {:ok, 1}}, &1)), do: Assets.changed()

    case for {stock, {:error, reason}} <- results, do: {stock, reason} do
      [] ->
        {[], :ok}

      [{_stock, reason} | _others] = failed ->
        unread = Enum.map(failed, &elem(&1, 0))
        Logger.warning("stocks not read on chain #{chain_id}: #{Enum.join(unread, ", ")}")
        {unread, {:error, reason}}
    end
  end

  defp admission(pad, stock, head) do
    with {:ok, [admitted, decimals, route]} <-
           Rpc.call_words(
             pad.contract,
             LabAbi.encode(pad.abi, "stockAdmission(address)", [stock]),
             head,
             3,
             pad.opts
           ) do
      case Abi.word_address(route) do
        {:ok, route} -> facts(stock, admitted == 1, decimals, route, head, pad.opts)
        :error when route == 0 -> {:ok, :never_admitted}
        :error -> {:error, :invalid_chain_response}
      end
    end
  end

  defp facts(stock, admitted, decimals, route, head, opts) do
    with {:ok, [feed]} <- Rpc.call_words(route, LabAbi.selector("feed()"), head, 1, opts),
         {:ok, feed} <- feed(feed),
         {:ok, name} <- Rpc.call_string(stock, LabAbi.selector("name()"), head, opts),
         {:ok, symbol} <- Rpc.call_string(stock, LabAbi.selector("symbol()"), head, opts) do
      {:ok,
       %{
         symbol: symbol,
         name: name,
         decimals: decimals,
         route: route,
         feed: feed,
         admitted: admitted
       }}
    end
  end

  defp feed(0), do: {:ok, nil}

  defp feed(word) do
    case Abi.word_address(word) do
      {:ok, feed} -> {:ok, feed}
      :error -> {:error, :invalid_chain_response}
    end
  end

  defp write(_chain_id, _stock, %{admitted: true} = saved, :never_admitted),
    do: written(Autolaunch.withdraw_stock_admission(saved, actor: @actor))

  defp write(_chain_id, _stock, _saved, :never_admitted), do: {:ok, 0}

  defp write(chain_id, stock, saved, facts) do
    if saved && Map.take(saved, @facts) == facts do
      {:ok, 0}
    else
      facts
      |> Map.merge(%{chain_id: chain_id, address: stock})
      |> Autolaunch.record_stock_admission(actor: @actor)
      |> written()
    end
  end

  defp written({:ok, _stock}), do: {:ok, 1}
  defp written({:error, reason}), do: {:error, reason}

  defp quantity(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))
end
