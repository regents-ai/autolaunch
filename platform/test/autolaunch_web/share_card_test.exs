defmodule AutolaunchWeb.ShareCardTest do
  @moduledoc """
  A shared auction's or token's picture keeps every word where X shows it:
  inside the left 660 or so of the 1200 pixels X's phone view keeps, and out
  of the bottom-left corner where X lays the site's name. The pictures are
  drawn for real from a stored auction with a long name, a long ticker and
  figures in the launch's own currency, the widest they come.
  """
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{AuctionPricePoint, TestSupport}
  alias AutolaunchWeb.ShareCard
  alias Vix.Vips.{Image, Operation}

  # Brighter than this is a word or a line; the panel, the strip and the
  # faint mark on the right stay below it.
  @bright 96

  # Inside the panel, clear of its rounded corners and the tangerine border.
  @right {660, 40, 490, 550}
  @x_corner {56, 554, 124, 52}

  setup do
    now = DateTime.utc_now()

    auction =
      TestSupport.project_auction(
        chain_id: 8453,
        title: "Artificial General Intelligence Research Collective",
        symbol: "WWWWWWWWWWWWWWWW",
        state: :active,
        opened_at: DateTime.add(now, -3600),
        current_clearing_price: "0.0000012345"
      )

    auction =
      Ash.update!(
        auction,
        %{floor_price: "0.000001", token_supply: Decimal.new(100_000_000_000)},
        action: :refresh_lab_market,
        actor: %System{}
      )
      |> Ash.load!(:fdv, actor: %System{})

    %{auction: auction, now: now}
  end

  test "SHARE_PICTURE_LEFT: an auction's words and price line stay where X shows them",
       %{auction: auction, now: now} do
    Ash.bulk_create!(
      for {price, block} <- Enum.with_index(["0.000001", "0.0000011", "0.0000012345"], 1) do
        %{
          auction_id: auction.id,
          block_number: block,
          log_index: 0,
          clock_block: block,
          clearing_price: price,
          sold: "0"
        }
      end,
      AuctionPricePoint,
      :record,
      actor: %System{}
    )

    assert {:ok, png} = ShareCard.auction_png(auction, now)
    assert_where_x_shows(png)
  end

  test "SHARE_PICTURE_LEFT: a token's words stay where X shows them",
       %{auction: auction, now: now} do
    token = %{market_cap: Decimal.new("123456.789"), price_quote: "0.0000012345"}

    assert {:ok, png} = ShareCard.token_png(auction, token, now)
    assert_where_x_shows(png)
  end

  defp assert_where_x_shows(png) do
    {:ok, picture} = Image.new_from_buffer(png)

    assert {Image.width(picture), Image.height(picture)} == {1200, 630}
    assert brightest(picture, {48, 100, 584, 480}) > @bright
    assert brightest(picture, @right) < @bright
    assert brightest(picture, @x_corner) < @bright
  end

  defp brightest(picture, {left, top, width, height}) do
    {:ok, area} = Operation.extract_area(picture, left, top, width, height)
    {:ok, colour} = Operation.extract_band(area, 0, n: 3)
    {:ok, {max, _where}} = Operation.max(colour)
    max
  end
end
