defmodule Autolaunch.PriceFeedHistory do
  @moduledoc """
  A Chainlink feed's prices back to a moment, read through its proxy at one
  block: every round of the proxy's current phase updated after `from`, and
  the round in force at `from` itself, oldest first, so a line drawn from them
  starts at `from` and ends at the latest price.

  Rounds are read newest first, sixteen at a time, a few at once, and at most
  600 of them: a feed that moved more often than that shows its newest 600.
  A phase's rounds count up from 1, so the walk ends at its first round.
  """

  import Bitwise

  alias Autolaunch.Chain.Rpc
  alias RegentChain.Call

  @batch 16
  @most 600
  @concurrency 8
  @read_timeout 20_000

  @type point :: {at :: non_neg_integer(), answer :: integer()}

  @doc """
  The feed's points since `from` (unix seconds), oldest first, with the
  feed's decimals.
  """
  @spec since(String.t(), non_neg_integer(), map(), keyword()) ::
          {:ok, %{decimals: non_neg_integer(), points: [point()]}} | {:error, atom()}
  def since(feed, from, block, opts) do
    with {:ok, decimals} <- Rpc.call_uint(feed, Call.encode("decimals()", []), block, opts),
         {:ok, [id, answer, _started, updated_at, _answered]} <-
           Rpc.call_words(feed, Call.encode("latestRoundData()", []), block, 5, opts) do
      phase = id >>> 64
      round = id &&& 0xFFFFFFFFFFFFFFFF
      latest = {updated_at, answer}

      with {:ok, older} <- walk(feed, phase, round - 1, from, [latest], block, opts),
           do: {:ok, %{decimals: decimals, points: older}}
    end
  end

  # `kept` is newest last read, oldest first. The walk stops once a round at
  # or before `from` is in hand, at the phase's first round, or at the cap.
  defp walk(_feed, _phase, round, from, [{oldest, _answer} | _newer] = kept, _block, _opts)
       when round < 1 or oldest <= from or length(kept) >= @most,
       do: {:ok, since_from(kept, from)}

  defp walk(feed, phase, round, from, kept, block, opts) do
    low = max(round - @batch + 1, 1)

    case rounds(feed, phase, low..round//1, block, opts) do
      {:ok, read} ->
        read = Enum.reject(read, fn {at, _answer} -> at == 0 end)
        walk(feed, phase, low - 1, from, read ++ kept, block, opts)

      error ->
        error
    end
  end

  # Drops every round before the one in force at `from`.
  defp since_from(points, from) do
    case Enum.split_while(points, fn {at, _answer} -> at <= from end) do
      {[], after_from} -> after_from
      {at_or_before, after_from} -> [List.last(at_or_before) | after_from]
    end
  end

  defp rounds(feed, phase, range, block, opts) do
    range
    |> Task.async_stream(
      fn round ->
        Rpc.call_words(
          feed,
          Call.encode("getRoundData(uint80)", [(phase <<< 64) + round]),
          block,
          5,
          opts
        )
      end,
      max_concurrency: @concurrency,
      timeout: @read_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, [_id, answer, _started, at, _answered]}}, {:ok, kept} ->
        {:cont, {:ok, [{at, answer} | kept]}}

      {:ok, {:error, _reason}}, _kept ->
        {:halt, {:error, :chain_unavailable}}

      {:exit, _reason}, _kept ->
        {:halt, {:error, :chain_unavailable}}
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end
end
