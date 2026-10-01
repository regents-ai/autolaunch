defmodule Autolaunch.AuctionFigures do
  @moduledoc """
  The launch figures an auction's stored record gives, worked out once for the
  market cards and the public API: the minimum it must raise, how much of that
  is met, and how many tokens it sells.
  """

  alias Autolaunch.Chain.Rpc

  @doc """
  What the auction must raise to launch, in whole quote-token units: the
  required raise plus one base unit, because the auction may count a bid placed
  after its first block one base unit short.
  """
  @spec minimum(map()) :: Decimal.t()
  def minimum(auction), do: auction |> minimum_units() |> Decimal.new()

  @doc "`minimum/1` as the plain decimal string the chain's units give."
  @spec minimum_units(map()) :: String.t()
  def minimum_units(%{required_currency_raised: required, quote_token_decimals: decimals}),
    do: required |> String.to_integer() |> Kernel.+(1) |> Rpc.format_units(decimals)

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
  sells 20 billion of its 100 billion tokens, a Memestake auction 500 million
  of its 1 billion, on either chain; the first four Memestake auctions sold
  up to 800 million.
  """
  @spec token_allocation(map()) :: Decimal.t()
  def token_allocation(%{kind: :agent}), do: Decimal.new(20_000_000_000)
  def token_allocation(%{kind: :stocks, contracts_version: :v1}), do: Decimal.new(800_000_000)
  def token_allocation(%{kind: :stocks, contracts_version: :v2}), do: Decimal.new(500_000_000)
end
