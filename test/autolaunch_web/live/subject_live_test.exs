defmodule AutolaunchWeb.SubjectLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  test "subject detail has an honest not-found state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/subjects/subject-42")
    html = render_async(view)

    assert has_element?(view, "#autolaunch-subject-detail", "Subject not found")
    assert html =~ "No public subject exists at subject-42."
    assert html =~ ~s(href="/subjects")
    refute html =~ "$"
  end

  test "canonical subject identity format edges round-trip through public URLs", %{conn: conn} do
    edge_ids = ["Z", "A._:-" <> String.duplicate("x", 123)]

    for subject_id <- edge_ids do
      subject = TestSupport.project_subject(subject_id: subject_id)
      assert subject.subject_id == subject_id

      {:ok, detail, _html} = live(conn, "/subjects/#{subject_id}")
      detail_html = render_async(detail)
      assert has_element?(detail, "#autolaunch-subject-detail", subject_id)
      assert detail_html =~ subject_id
    end
  end

  test "subject detail renders stored revenue and related token presentation", %{conn: conn} do
    subject =
      TestSupport.project_subject(
        subject_id: "subject:live:revenue",
        token_address: "0x3333333333333333333333333333333333333333"
      )

    auction =
      TestSupport.project_auction(
        title: "Canonical Subject Auction",
        summary: "Canonical subject summary.",
        symbol: "RST",
        state: :graduated
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        subject_id: subject.subject_id,
        name: "Legacy Related Token",
        symbol: "RST",
        summary: "Legacy related summary.",
        graduated_at: DateTime.utc_now()
      )

    {:ok, detail, _html} = live(conn, "/subjects/#{subject.subject_id}")
    html = render_async(detail)

    assert has_element?(detail, "#autolaunch-subject-detail")
    assert has_element?(detail, "#autolaunch-subject-detail", subject.subject_id)
    assert has_element?(detail, "#subject-revenue-title", "Revenue")
    assert has_element?(detail, "#subject-related-tokens", "Canonical Subject Auction · RST")
    assert has_element?(detail, "#subject-related-tokens", "Canonical subject summary.")
    refute has_element?(detail, "#subject-related-tokens", token.name)
    refute has_element?(detail, "#subject-related-tokens", token.summary)

    assert has_element?(
             detail,
             "#subject-related-tokens a[href='/tokens/#{token.id}']"
           )

    assert has_element?(detail, "#subject-recent-actions", "No subject actions yet.")
    assert has_element?(detail, "#subject-settlement-title", "Settlement history")
    assert has_element?(detail, "#subject-settlement-history", "No settlements yet.")
    assert html =~ "12000000"
    assert html =~ "3400000000000000000"
    assert html =~ "5000000"
    refute html =~ subject.id
    refute html =~ "$"
  end

  test "subject detail shows honest empty related records and no derived money", %{conn: conn} do
    subject =
      TestSupport.project_subject(
        subject_id: "subject:live:empty",
        subject_kind: "project",
        token_address: nil,
        splitter_address: nil,
        ingress_address: nil,
        treasury_address: nil,
        factory_address: nil,
        creator_address: nil,
        staker_pool_bps: nil,
        protocol_skim_bps_snapshot: nil,
        current_protocol_skim_bps: nil,
        protocol_fee_usdc_total_raw: nil,
        regent_emission_total_raw: nil,
        pending_buyback_usdc_raw: nil
      )

    {:ok, detail, _html} = live(conn, "/subjects/#{subject.subject_id}")
    html = render_async(detail)

    assert has_element?(detail, "#subject-related-tokens", "No related tokens yet.")
    assert has_element?(detail, "#subject-recent-actions", "No subject actions yet.")
    assert has_element?(detail, "#subject-settlement-history", "No settlements yet.")
    refute html =~ "Ready to settle"
    refute html =~ "$"
  end
end
