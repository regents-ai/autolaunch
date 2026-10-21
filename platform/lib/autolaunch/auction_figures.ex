defmodule Autolaunch.AuctionFigures do
  @moduledoc """
  The launch figures an auction's stored record gives, worked out once for the
  market cards and the public API: the minimum it must raise, how much of that
  is met, when to say it is short, and how many tokens it sells.
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

  @closing_seconds 30 * 60

  @doc """
  The moment from which to tell bidders the auction is short of its minimum:
  30 minutes before bidding is due to end, and only while everything bid so far
  adds up to less than the minimum. Nil when the auction is not live, its bids
  cover the minimum, or either figure is not recorded yet. Every minimum is
  tiny beside a real auction's bids, so at any other time it is not shown.
  """
  @spec minimum_warning_from(map()) :: DateTime.t() | nil
  def minimum_warning_from(
        %{state: :active, estimated_end_at: %DateTime{} = end_at, bid_volume: %Decimal{} = bids} =
          auction
      ) do
    if Decimal.lt?(bids, minimum(auction)), do: DateTime.add(end_at, -@closing_seconds)
  end

  def minimum_warning_from(_auction), do: nil

  @doc """
  The tokens the auction sells, fixed by its launch type: a Revstake auction
  sells 20 billion of its 100 billion tokens, a Memestock auction 497.5 million
  of its 1 billion, on either chain; the first four Memestock auctions sold
  up to 800 million.
  """
  @spec token_allocation(map()) :: Decimal.t()
  def token_allocation(%{kind: :agent}), do: Decimal.new(20_000_000_000)
  def token_allocation(%{kind: :stocks, contracts_version: :v1}), do: Decimal.new(800_000_000)
  def token_allocation(%{kind: :stocks, contracts_version: :v2}), do: Decimal.new(497_500_000)

  @price_digits 18

  @doc """
  A price, or a figure worked out from one, as the public API states it: a
  plain decimal string to 18 significant digits. A stored clearing price runs
  to about 90 decimal places, far past anything a bid or a trade can tell
  apart. It is rounded up, so a bid whose most per token is the stated
  clearing price still reaches it. Nil while there is no figure.
  """
  @spec stated(Decimal.t() | String.t() | nil) :: String.t() | nil
  def stated(nil), do: nil
  def stated(value) when is_binary(value), do: stated(Decimal.new(value, max_digits: :infinity))

  def stated(%Decimal{coef: coef, exp: exp} = value) do
    if Decimal.eq?(value, 0) do
      "0"
    else
      places = @price_digits - length(Integer.digits(coef)) - exp

      value
      |> Decimal.round(places, :ceiling)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)
    end
  end
end
