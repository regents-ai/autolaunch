defmodule Autolaunch.AuctionFiguresTest do
  @moduledoc """
  The minimum is named only in an auction's last 30 minutes of bidding, and
  only while its bids are short of it.
  """
  use ExUnit.Case, async: true

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
end
