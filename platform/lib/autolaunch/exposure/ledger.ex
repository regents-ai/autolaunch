defmodule Autolaunch.Exposure.Ledger do
  @moduledoc """
  The arithmetic of an `ExposureSeriesV1`, exactly as the contract does it, so
  a page can show what each print did and what a holding returns without
  asking the chain for every figure.

  Prices and ledgers are WAD (18 decimals) dollars per stock token. The two
  ledgers always add up to the last price: the After-hours ledger `night` and
  the Market-hours ledger `price - night`. Print 0 is the first close and sets
  both to half its price; an odd print is an open and moves After-hours by the
  change since the close; an even print after it is a close and moves
  Market-hours by the change since the open. A print that takes either ledger
  to zero or below ends the series, and the other leg takes everything.
  """

  @type step :: %{
          index: non_neg_integer(),
          price: pos_integer(),
          night: non_neg_integer(),
          day: non_neg_integer(),
          ended: nil | :overnight_depleted | :session_depleted
        }

  @doc """
  Every print applied in turn, from `prices` (print 0 first), stopping at the
  print that ends the series: each with the ledgers it left.
  """
  @spec path([pos_integer()]) :: [step()]
  def path(prices) do
    prices
    |> Enum.with_index()
    |> Enum.reduce_while({[], nil}, fn {price, index}, {applied, before} ->
      step = apply_print(before, index, price)

      if step.ended,
        do: {:halt, {[step | applied], step}},
        else: {:cont, {[step | applied], step}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp apply_print(nil, 0, price) do
    night = div(price, 2)
    step(0, price, night, if(night == 0, do: :overnight_depleted))
  end

  defp apply_print(%{price: last, night: night}, index, price) when rem(index, 2) == 1 do
    day = last - night

    if price <= day,
      do: step(index, price, 0, :overnight_depleted),
      else: step(index, price, price - day, nil)
  end

  defp apply_print(%{night: night}, index, price) do
    if price <= night,
      do: step(index, price, price, :session_depleted),
      else: step(index, price, night, nil)
  end

  defp step(index, price, night, ended),
    do: %{index: index, price: price, night: night, day: price - night, ended: ended}

  @doc """
  The raw stock the contract owes for `overnight` and `session` raw leg units
  after the series ended at `price` with After-hours ledger `night`: matched
  amounts are whole pairs and redeem exactly; only the unmatched rest rounds,
  down.
  """
  @spec owed(non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  def owed(overnight, session, price, night) when overnight > session,
    do: session + div((overnight - session) * night, price)

  def owed(overnight, session, price, night),
    do: overnight + div((session - overnight) * (price - night), price)

  @doc """
  What a redemption owing `owed` pays when the series holds `balance` raw stock
  for `accounted` raw stock of claims: the same fraction for everyone after a
  seizure, rounding down.
  """
  @spec paid(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def paid(owed, balance, accounted) when balance < accounted, do: div(owed * balance, accounted)
  def paid(owed, _balance, _accounted), do: owed
end
