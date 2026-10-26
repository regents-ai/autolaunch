defmodule AutolaunchWeb.VisitLogTest do
  # Invariant: whatever a caller or browser sends, a visit line holds only the
  # site's own names and shapes. Headers, reported lines and event fields that do
  # not fit are dropped or written as `other`, never copied into the log.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test, only: [conn: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias AutolaunchWeb.{VisitLog, VisitLogController}

  @where ~r/\A[A-Za-z0-9_.:\/@* -]{1,120}\z/
  @outcome ~r/\A[a-z0-9_]{1,48}\z/
  @visit ~r/\A[A-Za-z0-9_-]{22}\z/

  property "an event keeps only fitting where and outcome values" do
    check all(
            where <- one_of([string(:printable), string(:ascii)]),
            outcome <- string(:printable)
          ) do
      event = VisitLog.event("press", where, outcome, 3)

      assert Map.keys(event) |> Enum.sort() == [:ms, :name, :outcome, :where]
      assert event.where == where or event.where == "other"
      assert event.outcome == outcome or event.outcome == "other"
      assert event.where =~ @where
      assert event.outcome =~ @outcome
    end
  end

  property "a request's surface, tool and visit come only from fitting headers" do
    check all(
            path <- member_of(["/api/v1/auctions", "/auctions/ABC/1", "/"]),
            client <-
              one_of([
                string(:printable),
                member_of([
                  "webmcp/autolaunch_auctions",
                  "regents-cli/1.10.18 autolaunch auctions"
                ])
              ]),
            visit <- one_of([string(:printable), string(:alphanumeric, length: 22)])
          ) do
      conn =
        conn(:get, path)
        |> put_req_header("x-regent-client", client)
        |> put_req_header("x-regent-visit", visit)
        |> VisitLog.call([])

      surface = Logger.metadata()[:surface]
      assert surface in ~w(page webmcp cli agent_http)
      assert conn.assigns.visit == nil or conn.assigns.visit =~ @visit
      assert VisitLog.client(conn) == nil or VisitLog.client(conn) =~ @where

      case surface do
        "webmcp" ->
          assert "webmcp/" <> VisitLog.client(conn) == client

        "cli" ->
          assert String.starts_with?(client, "regents-cli/")

        "page" ->
          assert VisitLog.client(conn) == nil and
                   (path != "/api/v1/auctions" or conn.assigns.visit)

        "agent_http" ->
          assert VisitLog.client(conn) == nil and conn.assigns.visit == nil
      end
    end
  end

  test "a page's own script calling the API belongs to its visit, by header or cookie" do
    visit = String.duplicate("v", 22)
    api = fn -> conn(:get, "/api/v1/auctions") end

    for sent <- [
          put_req_header(api.(), "x-regent-visit", visit),
          Plug.Test.put_req_cookie(api.(), "_visit", visit)
        ] do
      conn = VisitLog.call(sent, [])
      assert {Logger.metadata()[:surface], conn.assigns.visit} == {"page", visit}
    end

    conn = VisitLog.call(api.(), [])
    assert {Logger.metadata()[:surface], conn.assigns.visit} == {"agent_http", nil}
  end

  property "the browser's reports keep only the lines a page can send, twenty at most" do
    sent =
      one_of([
        fixed_map(%{
          "name" => member_of(["page.error", "tool.unsent", "press.unsent", "visit.other"]),
          "where" =>
            one_of([
              string(:printable),
              member_of(["/portfolio/bids/7", "/nowhere", "autolaunch_auctions", "bid"])
            ]),
          "outcome" =>
            one_of([
              string(:printable),
              member_of(~w(error unhandledrejection unreachable outcome_unknown lost))
            ])
        }),
        term()
      ])

    check all(lines <- list_of(sent, max_length: 30)) do
      kept = VisitLogController.lines(%{"lines" => lines}, "www.example.com")

      assert length(kept) <= 20

      for {name, where, outcome} <- kept do
        case name do
          "page.error" ->
            assert outcome in ~w(error unhandledrejection)

            assert where in ["/portfolio/bids/:id", "unmatched"] or
                     where =~ ~r/\A\/[a-z\/:._-]*\z/

          "tool.unsent" ->
            assert outcome in ~w(unreachable outcome_unknown)
            assert where =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/

          "press.unsent" ->
            assert outcome == "lost"
            assert where =~ ~r/\A[a-z][a-z0-9_]{0,63}\z/
        end
      end
    end
  end

  test "a page's own path is written as its route, and a page the site lacks as unmatched" do
    assert [
             {"page.error", "/portfolio/bids/:id", "error"},
             {"page.error", "unmatched", "unhandledrejection"}
           ] =
             VisitLogController.lines(
               %{
                 "lines" => [
                   %{
                     "name" => "page.error",
                     "where" => "/portfolio/bids/a-private-bid",
                     "outcome" => "error"
                   },
                   %{
                     "name" => "page.error",
                     "where" => "/no/such/page",
                     "outcome" => "unhandledrejection"
                   }
                 ]
               },
               "www.example.com"
             )
  end
end
