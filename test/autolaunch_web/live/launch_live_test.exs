defmodule AutolaunchWeb.LaunchLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "launch detail has an honest not-found state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/launches/launch-42")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-launch-detail", "Launch not found")
    assert html =~ "No public launch exists at launch-42."
    assert html =~ ~s(href="/launches")
    refute html =~ "$"
  end

  test "canonical launch identity format edges round-trip through public URLs", %{conn: conn} do
    edge_ids = ["Z", "A._:-" <> String.duplicate("x", 123)]

    for job_id <- edge_ids do
      launch = TestSupport.project_launch(job_id: job_id)
      assert launch.job_id == job_id

      {:ok, detail, _html} = live(conn, "/launches/#{job_id}")
      detail_html = render_async(detail)
      assert has_element?(detail, "#autolaunch-launch-detail", job_id)
      assert detail_html =~ job_id
    end
  end

  test "launch detail renders progress, identities, linked auction, addresses, and times", %{
    conn: conn
  } do
    auction =
      TestSupport.project_auction(title: "Linked launch auction", state: :active)

    started_at = ~U[2026-07-30 12:00:00.000000Z]
    finished_at = ~U[2026-07-30 12:45:00.000000Z]

    launch =
      TestSupport.project_launch(
        job_id: "launch:live:complete",
        auction_id: auction.id,
        status: "complete",
        step: "record_addresses",
        agent_id: "agent:launch-detail",
        agent_name: "Launch Detail Agent",
        token_name: "Launch Detail Token",
        token_symbol: "LDT",
        started_at: started_at,
        finished_at: finished_at
      )

    {:ok, detail, _html} = live(conn, "/launches/#{launch.job_id}")
    html = render_async(detail)

    assert has_element?(detail, "#autolaunch-launch-detail", "Launch Detail Token · LDT")
    assert has_element?(detail, "#launch-progress-title", "Progress")
    assert has_element?(detail, "#launch-identity-title", "Agent and token")
    assert has_element?(detail, "#launch-auction-title", "Linked auction")
    assert has_element?(detail, "#launch-addresses-title", "Published addresses")
    assert has_element?(detail, "#autolaunch-launch-detail dt", "Auction rules")
    assert has_element?(detail, "#launch-times-title", "Timeline")
    assert html =~ launch.job_id
    assert html =~ "agent:launch-detail"
    assert html =~ "Launch Detail Agent"
    assert html =~ ~s(href="/auctions/#{auction.id}")
    assert html =~ "0x1111111111111111111111111111111111111111"
    assert html =~ "0x2222222222222222222222222222222222222222"
    assert html =~ "0x3333333333333333333333333333333333333333"
    assert html =~ "0x4444444444444444444444444444444444444444"
    assert html =~ "0x5555555555555555555555555555555555555555"
    assert html =~ "Jul 30, 2026 at 12:00 UTC"
    assert html =~ "Jul 30, 2026 at 12:45 UTC"
    refute html =~ "$"
  end
end
