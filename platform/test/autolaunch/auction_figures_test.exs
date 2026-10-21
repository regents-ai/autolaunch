defmodule Autolaunch.AuctionFiguresTest do
  @moduledoc """
  The minimum is named only in an auction's last 30 minutes of bidding, and
  only while its bids are short of it. A price the public API states keeps 18
  significant digits of the stored one, rounded up.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import AutolaunchWeb.Components.MinimumWarning

  alias Autolaunch.AuctionFigures

  # A live auction that must raise 100 units of a six-decimal currency.
  defp auction(minutes_left, bids) do
    %{
      state: :active,
      estimated_end_at: DateTime.add(DateTime.utc_now(), minutes_left, :minute),
      bid_volume: Decimal.new(bids),
      required_currency_raised: "100000000",
      quote_token_decimals: 6
    }
  end

  defp line(auction) do
    assigns = %{from: AuctionFigures.minimum_warning_from(auction)}

    rendered_to_string(~H"""
    <.minimum_warning id="line" from={@from}>Below minimum</.minimum_warning>
    """)
  end

  test "with more than 30 minutes left, bids short of the minimum show nothing" do
    assert line(auction(45, "5")) =~ ~r/<span[^>]* hidden[ >]/
  end

  test "in the last 30 minutes, bids that cover the minimum show nothing" do
    refute line(auction(10, "100.000001")) =~ "Below minimum"
  end

  test "in the last 30 minutes, bids short of the minimum show the line" do
    html = line(auction(10, "100"))
    assert html =~ "Below minimum"
    refute html =~ ~r/<span[^>]* hidden[ >]/
  end

  test "an auction that is not live, or has no bid total yet, shows nothing" do
    refute line(%{auction(10, "5") | state: :failed}) =~ "Below minimum"
    refute line(%{auction(10, "5") | bid_volume: nil}) =~ "Below minimum"
  end

  # A stored price as the chain gives it: up to 61 digits, tiny to huge.
  defp stored_price do
    gen all(digits <- integer(1..Integer.pow(10, 60)), exponent <- integer(-150..-20)) do
      Decimal.new(1, digits, exponent)
    end
  end

  property "a stated price keeps at most 18 significant digits and is the stored one rounded up" do
    check all(price <- stored_price(), max_runs: 2000) do
      stated = AuctionFigures.stated(Decimal.to_string(price, :normal))
      assert stated =~ ~r/^\d+(\.\d+)?$/

      significant =
        stated |> String.replace(".", "") |> String.trim_leading("0") |> String.trim_trailing("0")

      assert String.length(significant) <= 18

      # Never below the stored price, and less than one unit of its 18th
      # significant digit above it.
      %Decimal{coef: coef, exp: exp} = price
      unit = Decimal.new(1, 1, length(Integer.digits(coef)) + exp - 18)
      over = stated |> Decimal.new(max_digits: :infinity) |> Decimal.sub(price)
      assert Decimal.compare(over, 0) != :lt
      assert Decimal.compare(over, unit) == :lt
    end
  end
end
