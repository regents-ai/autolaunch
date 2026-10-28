defmodule AutolaunchWeb.SignInReadTest do
  @moduledoc """
  A read that fails while a page loads someone's sign-in never signs them out
  (Sean, 19 Oct 2026, "1. a"). As everywhere on the site
  (`AutolaunchWeb.ReadFailure`), a lost database connection is Try again: the
  try-again page (503), or on a page already open the plain "Something didn't
  load." state; any other failure is the plain error page (500). The browser is
  never told it is signed out, nothing is written for a sign-in that could not
  be read, and the same cookie is signed in once the read works. A sign-in that
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
  # The account is read with its ENS name, from this table.
  @ens "account_ens_identities"

  defp signed_in(conn) do
    account = TestSupport.register_creator!()
    {account, init_test_session(conn, %{human_account_id: account.id})}
  end

  defp signed_in?(conn) do
    conn |> get(@page) |> html_response(200) =~ @signed_in and
      match?(%{"authenticated" => true}, conn |> get("/auth/session") |> json_response(200))
  end

  test "SIGN_IN_READ_LOST_KEEPS_SIGN_IN: a lost connection is Try again, and signs no one out",
       %{conn: conn} do
    {_account, conn} = signed_in(conn)
    open = get(conn, @page <> "?from=share")
    lose_reads_of(@ens)

    {{503, _headers, body}, log} =
      with_log(fn -> assert_error_sent(503, fn -> get(conn, @page) end) end)

    assert body =~ "Try again"
    refute body =~ @sign_in
    assert log =~ "sign-in read connection_lost: "

    # The browser asks whether this sign-in still holds before it acts on a
    # sign-out made elsewhere; a failed read never answers that it does not.
    assert_error_sent(503, fn -> get(conn, "/auth/session") end)

    # A page whose socket connects while the read is lost says so and offers to
    # load the same address again.
    {:ok, view, _html} = live(open)
    assert has_element?(view, "#sign-in-unread", "Something didn’t load.")
    assert has_element?(view, ~s(#sign-in-unread a[href="#{@page}?from=share"]), "Try again")
    refute has_element?(view, "[data-account-target=sign-in]")

    restore_reads_of(@ens)
    assert signed_in?(conn)
  end

  test "a sign-in read that fails for any other reason is the plain error page, and signs no one out",
       %{conn: conn} do
    {_account, conn} = signed_in(conn)
    # Renamed for this case's sandboxed transaction only: 42P01, not a lost connection.
    Repo.query!(~s|ALTER TABLE autolaunch_app.#{@ens} RENAME TO #{@ens}_unread|)

    {{500, _headers, body}, log} =
      with_log(fn -> assert_error_sent(500, fn -> get(conn, @page) end) end)

    assert body =~ "Something went wrong"
    assert log =~ "sign-in read failed: Ash.Error."
    refute log =~ @ens
    refute log =~ "42P01"
    assert_error_sent(500, fn -> get(conn, "/auth/session") end)

    Repo.query!(~s|ALTER TABLE autolaunch_app.#{@ens}_unread RENAME TO #{@ens}|)
    assert signed_in?(conn)
  end

  # The case's own connection is cut as the account read starts.
  test "a connection cut during the sign-in read is the try-again page", %{conn: conn} do
    {_account, conn} = signed_in(conn)
    cut_when([:ash, :accounts, :read, :start], &(&1.resource == HumanAccount))

    {{503, _headers, body}, log} =
      with_log(fn -> assert_error_sent(503, fn -> get(conn, "/docs") end) end)

    assert body =~ "Try again"
    assert log =~ "sign-in read connection_lost: "
  end

  test "a lost sign-in read is a 503 for the signed-in wallet's positions and share video",
       %{conn: conn} do
    {account, conn} = signed_in(conn)
    lose_reads_of(@ens)

    {503, _headers, body} = assert_error_sent(503, fn -> get(conn, "/api/v1/me/positions") end)
    refute body =~ "authentication_required"

    {503, _headers, body} =
      assert_error_sent(503, fn ->
        get(conn, "/tokens/SANDY/abcd/wallets/#{account.wallet_address}/share.mp4")
      end)

    assert body =~ "Try again"
  end

  test "SIGN_IN_READ_LOST_WRITES_NOTHING: a page whose sign-in can't be read makes no code and saves no draft",
       %{conn: conn} do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)

    {account, conn} = signed_in(conn)
    {:ok, panel, _html} = live(conn, @page)
    {:ok, revstake, _html} = live(conn, "/create/revstake")
    {:ok, stocks, _html} = live(conn, "/create")
    lose_reads_of(@ens)

    # The page keeps showing the account it holds, but makes no pairing code.
    panel
    |> element("#shell-pairing-box")
    |> render_change(%{"harness" => "codex"})

    assert has_element?(panel, "#shell-pairing", "A pairing code couldn’t be made right now.")
    assert has_element?(panel, "#account-control [data-account-target=profile]")

    assert Repo.one(
             from code in "pairing_codes",
               prefix: "regent_agents",
               where: code.privy_user_id == ^account.privy_user_id,
               select: count()
           ) == 0

    # Nor does it save either kind of draft.
    revstake
    |> element("#launch-token-details")
    |> render_change(%{"launch_draft" => %{"name" => "Kept back"}})

    stocks
    |> element("#stocks-token-details")
    |> render_change(%{"stock_draft" => %{"name" => "Kept back"}})

    for view <- [revstake, stocks],
        do:
          assert(
            render(view) =~ "That change could not be saved just now. Try again in a moment."
          )

    actor = %Autolaunch.Actors.Human{human_account_id: account.id}
    assert {:ok, %{name: ""}} = Autolaunch.get_my_account_launch_draft(actor: actor)
    assert {:ok, %{name: ""}} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
  end

  test "a sign-in that has ended is still signed out", %{conn: conn} do
    account = TestSupport.register_creator!()
    {:ok, :bind, bound} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)
    age_sign_in!(bound, 30 * 86_400 + 60)
    conn = init_test_session(conn, SessionAuthority.session(bound))

    html = conn |> get(@page) |> html_response(200)
    assert html =~ @sign_in
    refute html =~ "Something didn’t load."

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
