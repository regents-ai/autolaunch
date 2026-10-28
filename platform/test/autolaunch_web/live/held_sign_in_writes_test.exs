defmodule AutolaunchWeb.HeldSignInWritesTest do
  @moduledoc """
  A page keeps showing its account while a re-read of the sign-in loses its
  connection (`AutolaunchWeb.Live.Session`), and nothing is written as that
  person meanwhile: every write reads the lease again first, so one whose
  sign-in has ended, or cannot be read, writes nothing.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import Phoenix.LiveViewTest

  alias Autolaunch.Accounts.{ConnectEns, SessionAuthority}
  alias Autolaunch.{AgentDrafts, Agents, LaunchActions, LaunchFixture, Repo, TestSupport}
  alias AutolaunchWeb.Live.Session

  @moduletag :capture_log
  @agent_wallet "0x" <> String.duplicate("ad", 20)
  @contract "0x" <> String.duplicate("5c", 20)
  @authority "session_authorities"
  @png File.read!("test/support/fixtures/launch-draft.png")

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  defp open(conn, path, account_id) do
    session = signed_in_session(account_id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    {view, session}
  end

  # The person signs out elsewhere, and the next read of the sign-in loses its
  # connection, so the open page keeps showing the account.
  defp signed_out_unread(session) do
    session
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> SessionAuthority.claim()
    |> SessionAuthority.revoke()

    lose_reads_of(@authority)
  end

  defp settle(view) do
    render_async(view, 2_000)
    _ = render(view)
    GenServer.stop(view.pid)
    restore_reads_of(@authority)
  end

  defp drafts(table, account_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM autolaunch_app.#{table} WHERE human_account_id = $1",
        [account_id]
      )

    count
  end

  defp drop_drafts(table, account_id),
    do:
      Repo.query!("DELETE FROM autolaunch_app.#{table} WHERE human_account_id = $1", [account_id])

  test "HELD_TREASURY_TICK_WRITES_NOTHING: a page whose sign-in ended and can't be read confirms no treasury",
       %{conn: conn} do
    LaunchFixture.install()
    setup = LaunchFixture.actor()
    account = setup[:account]

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    RegentAgents.pair_agent!(code.code, "Treasury Agent", :codex,
      actor: %RegentAgents.Agent{wallet: @agent_wallet}
    )

    {:ok, agent, _account} = Agents.resolve(@agent_wallet)

    {:ok, draft} =
      AgentDrafts.save(
        "revstake",
        %{"treasury" => @contract, "treasury_path" => "contract"},
        agent
      )

    {view, session} = open(conn, "/create/revstake", account.id)
    assert view |> element("#launch-agent-treasury") |> render() =~ @contract
    render_async(view, 5_000)
    for child <- live_children(view), do: render_async(child, 5_000)

    signed_out_unread(session)

    view
    |> element("#launch-agent-treasury")
    |> render_change(%{"treasury" => @contract, "confirmed" => "true"})

    settle(view)

    assert LaunchFixture.refusal(LaunchActions.prepare(draft.id, setup[:wallet], setup[:opts])) ==
             :agent_treasury_unconfirmed
  end

  test "HELD_PAGE_MAKES_NO_DRAFT: a closed review or an agent's save starts no draft for a held account",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    for {path, table, message} <- [
          {"/create/revstake", "launch_drafts", {:launch_review, :launched}},
          {"/create", "stock_launch_drafts", {:launch_review, :closed}},
          {"/create", "stock_launch_drafts", {:agent_draft_saved, "memestock"}}
        ] do
      {view, session} = open(conn, path, account.id)
      render_async(view, 2_000)
      # As after a launch listed the draft: there is none until the page starts one.
      drop_drafts(table, account.id)

      signed_out_unread(session)
      send(view.pid, message)
      settle(view)

      assert drafts(table, account.id) == 0, inspect({path, message})
    end
  end

  test "WRITE_FAILURE_IS_NOT_A_SIGN_IN_READ: a write that fails under a lease raises as itself" do
    account = TestSupport.register_creator!()
    lease = current_lease(account.id)

    {raised, log} =
      ExUnit.CaptureLog.with_log(fn ->
        assert_raise Postgrex.Error, fn ->
          SessionAuthority.transact_lease(lease.lineage, account.id, fn _account ->
            Repo.query!("SELECT * FROM autolaunch_app.no_such_table")
          end)
        end
      end)

    assert %Postgrex.Error{postgres: %{code: :undefined_table}} = raised
    refute log =~ "sign-in read"
  end

  test "LEASE_WRITE_ON_A_CUT_CONNECTION_SAYS_TRY_AGAIN: a connection gone before the write begins is a try-again" do
    writes = [
      {fn lease ->
         Session.transact(%{assigns: %{session_lease: lease}}, fn -> flunk("wrote") end)
       end, {:error, :sign_in_unread}},
      {fn lease -> ConnectEns.record_name(lease.lineage, lease.account_id, %{}) end,
       {:error, :try_again}}
    ]

    # Each cut takes the case's rows with it, so each write starts afresh.
    for {write, answer} <- writes do
      account = TestSupport.register_creator!()
      lease = current_lease(account.id)
      cut_now()

      {result, log} = ExUnit.CaptureLog.with_log(fn -> write.(lease) end)
      assert result == answer
      assert log =~ "sign-in lease connection_lost"
    end
  end

  test "IMAGE_UPLOAD_HELD_SAYS_TRY_AGAIN_OR_SIGNS_OUT: a picture saved on a held page" do
    for {path, field} <- [{"/create/revstake", :launch_image}, {"/create", :stocks_image}] do
      account = TestSupport.register_creator!()
      {view, session} = open(build_conn(), path, account.id)
      render_async(view, 2_000)
      picture = [%{name: "launch.png", content: @png, type: "image/png"}]

      # The connection is lost as the picture is saved.
      lose_reads_of(@authority)
      upload = file_input(view, "#" <> upload_form(view), field, picture)
      render_upload(upload, "launch.png")
      notice = view |> element(".image-upload [role=alert]") |> render()
      assert notice =~ "Try again", path
      refute notice =~ "PNG", path
      restore_reads_of(@authority)

      # The sign-in has ended: the page signs out instead of blaming the file.
      session
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> SessionAuthority.claim()
      |> SessionAuthority.revoke()

      upload = file_input(view, "#" <> upload_form(view), field, picture)
      render_upload(upload, "launch.png")
      assert has_element?(view, ~s([data-account-target="sign-in"])), path
      refute render(view) =~ "That file is not a complete PNG", path
    end
  end

  # The form that holds the page's picture input.
  defp upload_form(view) do
    [form] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("form:has(input[type=file])")
      |> LazyHTML.attribute("id")

    form
  end

  test "a write behind a fresh check runs only for a lease that reads as current now" do
    account = TestSupport.register_creator!()
    lease = current_lease(account.id)
    write = fn read -> {:ok, read.id} end

    assert Session.fresh(lease, write) == {:ok, account.id}

    lose_reads_of(@authority)
    assert Session.fresh(lease, write) == {:error, :sign_in_unread}
    restore_reads_of(@authority)

    SessionAuthority.revoke(%{lineage: lease.lineage, generation: 1})
    assert Session.fresh(lease, write) == {:error, :session_unavailable}
    assert Session.fresh(nil, write) == {:error, :session_lease_required}
  end
end
