defmodule AutolaunchWeb.ShareMarketTest do
  @moduledoc """
  The share picture and video of covered calls and of an Isolated Exposure to After-hours Stocks
  series: everyone's at the market's own address, a signed-in person's own only
  at their wallet's address and only once they switch it on in the share window,
  each a real picture and a real video drawn from the chain doubles
  (`Autolaunch.CoveredCallsChain`, `Autolaunch.ExposureChain`).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Autolaunch.{CoveredCallsChain, ExposureChain, TestSupport}
  alias AutolaunchWeb.Components.ShareMarket
  alias AutolaunchWeb.ShareVideo
  alias AutolaunchWeb.ShareVideo.MarketStory

  @moduletag :capture_log

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    :ok
  end

  describe "covered calls" do
    setup do
      CoveredCallsChain.install()
      :ok
    end

    test "the story closes on the price, the lowest premium and the open strikes" do
      assert {:ok, story} = MarketStory.covered_calls("AMZNc", nil)

      assert story.figures == [{"Price", "$254.00"}, {"Calls from", "$3.00"}]
      assert story.badge == "1 call open"
      assert [%{price: 260.0, label: "$260.00 strike"}] = story.levels
      assert story.now == CoveredCallsChain.now()
      assert List.last(story.line) == {CoveredCallsChain.now(), 254.0}
    end

    test "a seller's own story closes on the premium their calls earned, after the 1% fee" do
      assert {:ok, story} =
               MarketStory.covered_calls("AMZNc", "0x2222222222222222222222222222222222222222")

      # 4 calls sold at $3.00: $12.00, less $0.12 to REGENT staking.
      assert story.figures == [{"Earned", "$11.88"}, {"Calls held", "0 AMZNc"}]
    end

    test "calls held count only while they can still be used, never once lapsed" do
      now = CoveredCallsChain.now()
      lapsed = now - Autolaunch.CoveredCalls.Terms.exercise_window() - 3_600

      CoveredCallsChain.put(%{
        held: 2 * CoveredCallsChain.unit(),
        listings: [CoveredCallsChain.listing(%{}), CoveredCallsChain.listing(%{expiry: lapsed})]
      })

      assert {:ok, %{figures: [_earned, {"Calls held", "2.00 AMZNc"}]}} =
               MarketStory.covered_calls("AMZNc", "0x3333333333333333333333333333333333333333")
    end

    test "the picture is drawn for a market the site offers, and nowhere else", %{conn: conn} do
      conn = get(conn, "/stock/covered-call/AMZNc/share.png")
      assert <<@png, _rest::binary>> = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]

      assert_error_sent(404, fn -> get(build_conn(), "/stock/covered-call/TSLAc/share.png") end)
    end

    test "everyone's video is made from the chain and served once made", %{conn: conn} do
      now = DateTime.utc_now()
      assert {:waiting, 0} = ShareVideo.fetch_market(:covered_calls, "AMZNc", nil, nil, now)

      assert %{success: 1} = Oban.drain_queue(queue: :share_videos)

      assert {:ok, <<_size::32, "ftyp", _rest::binary>>} =
               ShareVideo.fetch_market(:covered_calls, "AMZNc", nil, nil, now)

      conn = get(conn, ShareVideo.market_url(:covered_calls, "AMZNc", nil, now))
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert response(conn, 200) =~ "ftyp"
    end

    test "a wallet's video is there only for the signed-in account that links it",
         %{conn: conn} do
      account = TestSupport.register_creator!()
      path = "/stock/covered-call/AMZNc/wallets/#{account.wallet_address}/share.mp4"

      assert_error_sent(404, fn -> get(conn, path) end)

      other = TestSupport.register_creator!()
      signed_in = init_test_session(build_conn(), %{human_account_id: other.id})
      assert_error_sent(404, fn -> get(signed_in, path) end)

      signed_in = init_test_session(build_conn(), %{human_account_id: account.id})
      assert %{"ahead" => 0} = signed_in |> get(path) |> json_response(202)
    end

    test "each wallet of an account has its own video, never another wallet's" do
      account = TestSupport.register_creator!()
      now = DateTime.utc_now()
      first = "0x" <> String.duplicate("a", 40)
      second = "0x" <> String.duplicate("b", 40)

      assert {:waiting, _ahead} =
               ShareVideo.fetch_market(:covered_calls, "AMZNc", first, account.id, now)

      assert {:waiting, _ahead} =
               ShareVideo.fetch_market(:covered_calls, "AMZNc", second, account.id, now)

      assert %{success: 2} = Oban.drain_queue(queue: :share_videos)

      assert {:ok, mine} =
               ShareVideo.fetch_market(:covered_calls, "AMZNc", first, account.id, now)

      assert {:ok, theirs} =
               ShareVideo.fetch_market(:covered_calls, "AMZNc", second, account.id, now)

      assert mine =~ "ftyp" and theirs =~ "ftyp"

      wallets =
        Autolaunch.Repo.all(
          from(r in "share_video_requests",
            where: r.subject == "AMZNc" and not is_nil(r.wallet),
            select: r.wallet
          )
        )

      assert Enum.sort(wallets) == [first, second]
    end

    test "the share window starts with everyone's video; a person's own waits behind its switch" do
      account = TestSupport.register_creator!()

      signed_in =
        render_component(&ShareMarket.share_market/1,
          id: "share",
          kind: :covered_calls,
          subject: "AMZNc",
          account_control: %{kind: :signed_in, wallet_address: account.wallet_address}
        )

      assert signed_in =~ ~r{data-share-video="[^"]*/stock/covered-call/AMZNc/share\.mp4}

      assert signed_in =~
               "/stock/covered-call/AMZNc/wallets/#{String.downcase(account.wallet_address)}/share.mp4"

      assert signed_in =~ ~s(<input type="checkbox" data-share-mine)
      refute signed_in =~ "checked"
      assert signed_in =~ "My calls"

      signed_out =
        render_component(&ShareMarket.share_market/1,
          id: "share",
          kind: :covered_calls,
          subject: "AMZNc",
          account_control: %{kind: :signed_out}
        )

      refute signed_out =~ "data-share-mine"
      refute signed_out =~ "/wallets/"
    end
  end

  test "switched off, covered calls' picture and videos are not there", %{conn: conn} do
    assert conn |> get("/stock/covered-call/AMZNc/share.png") |> response(404)
    assert build_conn() |> get("/stock/covered-call/AMZNc/share.mp4") |> response(404)
  end

  test "switched off, a series' picture and videos are not there", %{conn: conn} do
    series = ExposureChain.series()
    assert conn |> get("/stock/isolated-afters/#{series}/share.png") |> response(404)
    assert build_conn() |> get("/stock/isolated-afters/#{series}/share.mp4") |> response(404)
  end

  describe "Isolated Exposure to After-hours Stocks" do
    setup do
      ExposureChain.install()
      :ok
    end

    test "the feed's rounds since a moment, from the one in force then" do
      now = ExposureChain.now()
      {:ok, config} = Autolaunch.Exposure.Deployment.current()
      {:ok, block, opts} = Autolaunch.Exposure.Chain.latest(config.lab)

      assert {:ok, %{decimals: 8, points: points}} =
               Autolaunch.PriceFeedHistory.since(ExposureChain.feed(), now - 86_400, block, opts)

      assert points == [
               {now - 3 * 86_400, 25_000_000_000},
               {now - 7_200, 25_600_000_000},
               {now - 60, 25_700_000_000}
             ]

      assert {:ok, %{points: [{_in_force, 25_600_000_000}, _latest]}} =
               Autolaunch.PriceFeedHistory.since(ExposureChain.feed(), now - 3_600, block, opts)
    end

    test "a series that ended before its first price shows the price and that none was applied" do
      ExposureChain.put(%{status: 2, end_reason: 4, prices: []})

      assert {:ok, story} = MarketStory.exposure(ExposureChain.series(), nil)
      assert [{"Price", "$257.00"}, {"Prices", "None applied"}] = story.figures
      assert story.bands == []
      assert story.badge == "Ended"
    end

    test "a wallet's own holdings, only at the address of the account that links it",
         %{conn: conn} do
      account = TestSupport.register_creator!()

      path =
        "/stock/isolated-afters/#{ExposureChain.series()}/wallets/#{account.wallet_address}/share.mp4"

      assert_error_sent(404, fn -> get(conn, path) end)

      signed_in = init_test_session(build_conn(), %{human_account_id: account.id})
      assert %{"ahead" => 0} = signed_in |> get(path) |> json_response(202)

      assert {:ok, %{figures: [{"After-hours", "0 " <> _}, {"Market-hours", "0 " <> _}]}} =
               MarketStory.exposure(ExposureChain.series(), account.wallet_address)
    end

    test "the story colours the line by window and closes on what each token is worth" do
      assert {:ok, story} = MarketStory.exposure(ExposureChain.series(), nil)
      [close, open | _rest] = ExposureChain.boundaries()

      assert [%{from: ^close, to: ^open, window: :after}, %{from: ^open, window: :market} | _rest] =
               story.bands

      # The window in progress runs past now, so the line's tip takes its colour.
      assert Enum.any?(
               story.bands,
               &(&1.from <= ExposureChain.now() and ExposureChain.now() < &1.to)
             )

      assert [{"After-hours", "$" <> _night}, {"Market-hours", "$" <> _day}] = story.figures
      assert length(story.dots) == length(story.bands)
      assert story.badge == "Live"
    end

    test "the picture and everyone's video are there for a series the site offers",
         %{conn: conn} do
      series = ExposureChain.series()
      "0x" <> hex = series
      conn = get(conn, "/stock/isolated-afters/0x#{String.upcase(hex)}/share.png")
      assert <<@png, _rest::binary>> = response(conn, 200)

      now = DateTime.utc_now()
      assert {:waiting, 0} = ShareVideo.fetch_market(:exposure, series, nil, nil, now)
      assert %{success: 1} = Oban.drain_queue(queue: :share_videos)

      assert {:ok, <<_size::32, "ftyp", _rest::binary>>} =
               ShareVideo.fetch_market(:exposure, series, nil, nil, now)

      assert_error_sent(404, fn ->
        get(build_conn(), "/stock/isolated-afters/0x#{String.duplicate("1", 40)}/share.png")
      end)
    end
  end
end
