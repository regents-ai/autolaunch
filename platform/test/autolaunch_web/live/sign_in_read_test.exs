defmodule AutolaunchWeb.SignInReadTest do
  @moduledoc """
  A read that fails for a moment while a page loads someone's sign-in never
  signs them out (Sean, 19 Oct 2026, "1. a"): the page says something didn't
  load and offers to load it again, the browser is never told it is signed out,
  and the same cookie is signed in again once the read works. A sign-in that
  has ended is still signed out.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts.{HumanAccount, SessionAuthority}
  alias Autolaunch.{Repo, TestSupport}

  @moduletag :capture_log

  @page "/how-it-works"
  @signed_in ~s(data-account-target="profile")
  @sign_in ~s(data-account-target="sign-in")
  @unread "Something didn’t load."

  test "SIGN_IN_READ_FAILURE_KEEPS_SIGN_IN: a failed read shows the plain state and signs no one out",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    conn = init_test_session(conn, %{human_account_id: account.id})
    assert conn |> get(@page) |> html_response(200) =~ @signed_in

    # The account's ENS name is read with it. Renamed for this case's sandboxed
    # transaction only, so that read fails with 42P01 (undefined_table).
    Repo.query!(
      "ALTER TABLE autolaunch_app.account_ens_identities RENAME TO account_ens_identities_unread"
    )

    {html, log} = with_log(fn -> conn |> get(@page) |> html_response(200) end)
    refute html =~ @sign_in
    refute html =~ @signed_in
    assert html =~ @unread
    assert html =~ ~r/id="sign-in-unread".*?href="#{@page}"/s
    assert log =~ "sign-in read failed: Ash.Error."
    refute log =~ "account_ens_identities"
    refute log =~ "42P01"

    {:ok, view, _html} = live(conn, @page)
    assert has_element?(view, "#sign-in-unread", "Something didn’t load.")
    refute has_element?(view, "[data-account-target=sign-in]")

    # The browser asks whether this sign-in still holds before it acts on a
    # sign-out made elsewhere; a failed read never answers that it does not.
    assert %{"error" => %{"code" => "account_unavailable"}} =
             conn |> get("/auth/session") |> json_response(503)

    Repo.query!(
      "ALTER TABLE autolaunch_app.account_ens_identities_unread RENAME TO account_ens_identities"
    )

    assert conn |> get(@page) |> html_response(200) =~ @signed_in

    assert %{"authenticated" => true} =
             conn |> get("/auth/session") |> json_response(200)
  end

  # The connection is cut as the account read starts. A page served without
  # LiveView reads the sign-in once, so the plain state is all it can show.
  test "a lost connection during the sign-in read is the same plain state, logged as one",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    conn = init_test_session(conn, %{human_account_id: account.id})
    cut_when([:ash, :accounts, :read, :start], &(&1.resource == HumanAccount))

    {html, log} = with_log(fn -> conn |> get("/docs") |> html_response(200) end)
    refute html =~ @sign_in
    refute html =~ @signed_in
    assert html =~ @unread
    assert html =~ ~r/id="sign-in-unread".*?href="\/docs"/s
    assert log =~ "sign-in read connection_lost: "
  end

  test "a sign-in that has ended is still signed out", %{conn: conn} do
    account = TestSupport.register_creator!()
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    age_sign_in!(bound, 30 * 86_400 + 60)
    conn = init_test_session(conn, SessionAuthority.session(bound))

    html = conn |> get(@page) |> html_response(200)
    assert html =~ @sign_in
    refute html =~ @unread

    assert %{"authenticated" => false} =
             conn |> get("/auth/session") |> json_response(200)
  end

  # Moves the recorded sign-in `seconds` into the past.
  defp age_sign_in!(%{lineage: lineage}, seconds) do
    {1, nil} =
      from(row in "session_authorities",
        where: row.lineage_digest == ^:crypto.hash(:sha256, lineage),
        update: [
          set: [signed_in_at: fragment("? - ? * interval '1 second'", row.signed_in_at, ^seconds)]
        ]
      )
      |> Repo.update_all([])
  end
end
