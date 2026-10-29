defmodule AutolaunchWeb.ShareMarketTest do
  @moduledoc """
  The share picture and video of covered calls and of an After-hours Exposure
  series: everyone's at the market's own address, a signed-in person's own only
  at their wallet's address and only once they switch it on in the share window,
  each a real picture and a real video drawn from the chain doubles
  (`Autolaunch.CoveredCallsChain`, `Autolaunch.ExposureChain`).
  """
  use AutolaunchWeb.ConnCase, async: false

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
      assert story.mine?
    end

    test "the picture is drawn for a market the site offers, and nowhere else", %{conn: conn} do
      conn = get(conn, "/covered-calls/AMZNc/share.png")
      assert <<@png, _rest::binary>> = response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]

      assert_error_sent(404, fn -> get(build_conn(), "/covered-calls/TSLAc/share.png") end)
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
      path = "/covered-calls/AMZNc/wallets/#{account.wallet_address}/share.mp4"

      assert_error_sent(404, fn -> get(conn, path) end)

      other = TestSupport.register_creator!()
      signed_in = init_test_session(build_conn(), %{human_account_id: other.id})
      assert_error_sent(404, fn -> get(signed_in, path) end)

      signed_in = init_test_session(build_conn(), %{human_account_id: account.id})
      assert %{"ahead" => 0} = signed_in |> get(path) |> json_response(202)
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

      assert signed_in =~ ~r{data-share-video="[^"]*/covered-calls/AMZNc/share\.mp4}

      assert signed_in =~
               "/covered-calls/AMZNc/wallets/#{String.downcase(account.wallet_address)}/share.mp4"

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
    assert conn |> get("/covered-calls/AMZNc/share.png") |> response(404)
    assert build_conn() |> get("/covered-calls/AMZNc/share.mp4") |> response(404)
  end

  describe "After-hours Exposure" do
    setup do
      ExposureChain.install()
      :ok
    end

    test "the story colours the line by window and closes on what each token is worth" do
      assert {:ok, story} = MarketStory.exposure(ExposureChain.series(), nil)
      [close, open | _rest] = ExposureChain.boundaries()

      assert [%{from: ^close, to: ^open, window: :after}, %{from: ^open, window: :market} | _rest] =
               story.bands

      assert Enum.all?(story.bands, &(&1.to <= ExposureChain.now()))
      assert [{"After-hours", "$" <> _night}, {"Market-hours", "$" <> _day}] = story.figures
      assert length(story.dots) == length(story.bands)
      assert story.badge == "Live"
    end

    test "the picture and everyone's video are there for a series the site offers",
         %{conn: conn} do
      series = ExposureChain.series()
      "0x" <> hex = series
      conn = get(conn, "/after-hour-stocks/0x#{String.upcase(hex)}/share.png")
      assert <<@png, _rest::binary>> = response(conn, 200)

      now = DateTime.utc_now()
      assert {:waiting, 0} = ShareVideo.fetch_market(:exposure, series, nil, nil, now)
      assert %{success: 1} = Oban.drain_queue(queue: :share_videos)

      assert {:ok, <<_size::32, "ftyp", _rest::binary>>} =
               ShareVideo.fetch_market(:exposure, series, nil, nil, now)

      assert_error_sent(404, fn ->
        get(build_conn(), "/after-hour-stocks/0x#{String.duplicate("1", 40)}/share.png")
      end)
    end
  end
end
