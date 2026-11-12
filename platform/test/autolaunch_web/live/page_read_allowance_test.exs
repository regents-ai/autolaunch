defmodule AutolaunchWeb.PageReadAllowanceTest do
  @moduledoc """
  A visitor's presses of a page's own read buttons (Check on the bid lookup,
  Read again and Refresh balances on a token's pool, Refresh on REGENT Fees)
  read the chain only within the viewer's allowance, on Base and Robinhood
  alike: past it a press reads nothing, and the page stays as it is.

  The allowance here is two presses, the chain is a stand-in that answers
  every read as unavailable and tells the test of each one, and each test
  visits from its own address.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.BaseRpcStub
  alias Autolaunch.TestSupport
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  @robinhood 4_663

  setup %{conn: conn} do
    limits = Application.fetch_env!(:autolaunch, :limits)

    Application.put_env(
      :autolaunch,
      :limits,
      Keyword.put(limits, :page_read, limit: 2, window_seconds: 3600)
    )

    prelaunch = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)

    on_exit(fn ->
      Application.put_env(:autolaunch, :limits, limits)
      Application.put_env(:autolaunch, :prelaunch_read_only, prelaunch)
    end)

    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> :unavailable end)

    from = {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}
    %{conn: %{conn | remote_ip: from}}
  end

  test "Refresh on REGENT Fees reads the launches twice, then leaves the page as it is",
       %{conn: conn} do
    auction = graduated("FEES", :stocks)
    {:ok, view, _html} = live(conn, "/convert")

    assert_allowance(view, fn -> render_click(view, "reload") end)
    assert has_element?(view, "#convert-base-#{auction.id}-row")
  end

  test "Read again on a token's pool reads it twice, then leaves the page as it is",
       %{conn: conn} do
    auction = graduated("POOL", :agent)
    {:ok, view, _html} = live(conn, Paths.token(auction))

    assert_allowance(view, fn -> render_click(view, "reload_pool") end)
  end

  test "the bid lookup reads a bid twice, then reads nothing", %{conn: conn} do
    auction = graduated("LOOK", :agent)
    {:ok, view, _html} = live(conn, Paths.auction(auction))

    assert_allowance(view, fn -> render_submit(view, "check_bid", %{"bid" => "0"}) end)
  end

  test "Refresh balances on a token's page reads its pool twice, then reads nothing",
       %{conn: conn} do
    auction = graduated("BALS", :agent)
    {:ok, view, _html} = live(conn, Paths.token(auction))

    assert_allowance(view, fn -> render_click(view, "refresh_balances") end)
  end

  describe "on Robinhood" do
    setup do
      put_env(:autolaunch_robinhood_chain_id, @robinhood)

      put_env(
        :autolaunch_robinhood_deployment,
        Path.expand("../../fixtures/robinhood-deployment.json", __DIR__)
      )
    end

    test "Read again on a token's pool reads it twice, then leaves the page as it is",
         %{conn: conn} do
      auction = graduated("RPOOL", :stocks, @robinhood)
      {:ok, view, _html} = live(conn, Paths.token(auction))

      assert_allowance(view, fn -> render_click(view, "reload_pool") end)
    end

    test "Refresh balances on a token's page reads its pool twice, then reads nothing",
         %{conn: conn} do
      auction = graduated("RBALS", :stocks, @robinhood)
      {:ok, view, _html} = live(conn, Paths.token(auction))

      assert_allowance(view, fn -> render_click(view, "refresh_balances") end)
    end

    test "the bid lookup reads a bid twice, then reads nothing", %{conn: conn} do
      auction = graduated("RLOOK", :stocks, @robinhood)
      {:ok, view, _html} = live(conn, Paths.auction(auction))

      assert_allowance(view, fn -> render_submit(view, "check_bid", %{"bid" => "0"}) end)
    end
  end

  # Two presses each read the chain; the third reads nothing.
  defp assert_allowance(view, press) do
    render_async(view, 5_000)

    for _press <- 1..2 do
      flush()
      press.()
      render_async(view, 5_000)
      assert_received {:rpc, _method, _params}
    end

    flush()
    press.()
    render_async(view, 5_000)
    refute_received {:rpc, _method, _params}
  end

  defp flush do
    receive do
      {:rpc, _method, _params} -> flush()
    after
      0 -> :ok
    end
  end

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, key, previous),
        else: Application.delete_env(:autolaunch, key)
    end)
  end

  defp graduated(symbol, kind, chain_id \\ 8453) do
    stored =
      TestSupport.project_auction(
        chain_id: chain_id,
        kind: kind,
        symbol: symbol,
        state: :graduated,
        token_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      )

    TestSupport.project_token(
      auction_id: stored.id,
      name: "Launch #{symbol}",
      symbol: symbol,
      graduated_at: DateTime.utc_now()
    )

    {:ok, auction} = Paths.find_auction(symbol, String.slice(stored.auction_address, -5, 5))
    auction
  end
end
