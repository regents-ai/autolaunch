defmodule Autolaunch.AuctionFigures do
  @moduledoc """
  The launch figures an auction's stored record gives, worked out once for the
  market cards and the public API: the minimum it must raise, how much of that
  is met, and how many tokens it sells.
  """

  alias Autolaunch.Chain.Rpc

  @doc "What the auction must raise to launch, in whole quote-token units."
  @spec minimum(map()) :: Decimal.t()
  def minimum(%{required_currency_raised: required, quote_token_decimals: decimals}),
    do: required |> String.to_integer() |> Rpc.format_units(decimals) |> Decimal.new()

  @doc """
  How much of the minimum is raised, as a whole percent rounded down; a minimum
  met many times over still reads 100. Nil until the amount raised is recorded.
  """
  @spec percent_met(map()) :: 0..100 | nil
  def percent_met(%{currency_raised: %Decimal{} = raised} = auction) do
    minimum = minimum(auction)

    if Decimal.gt?(minimum, 0),
      do:
        raised
        |> Decimal.div(minimum)
        |> Decimal.mult(100)
        |> Decimal.round(0, :down)
        |> Decimal.to_integer()
        |> min(100)
  end

  def percent_met(_auction), do: nil

  @doc """
  The tokens the auction sells, fixed by its launch type: a Revstake auction
  sells 10 billion of its 100 billion tokens, a Memestake auction 800 million
  of its 1 billion, on either chain.
  """
  @spec token_allocation(map()) :: Decimal.t()
  def token_allocation(%{kind: :agent}), do: Decimal.new(10_000_000_000)
  def token_allocation(%{kind: :stocks}), do: Decimal.new(800_000_000)
end
