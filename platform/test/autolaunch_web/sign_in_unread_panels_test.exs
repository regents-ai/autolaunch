defmodule AutolaunchWeb.SignInUnreadPanelsTest do
  @moduledoc """
  A wallet panel follows the same rule as a page (`AutolaunchWeb.ReadFailure`):
  when the signed-in account can't be read because the connection was lost, it
  says to try again and never to sign in, and sends nothing; any other failure
  is a real error. Every wallet panel reads the account the same way
  (`AutolaunchWeb.OnchainSteps.adopt/1`); the covered-call Buy ticket stands for
  them here. Connect ENS says to try again the same way, and tells a name
  another account holds apart from a try-again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, CoveredCallsChain, Repo, TestSupport}
  alias Autolaunch.Accounts.ConnectEns
  alias Autolaunch.Actors.System
  alias AutolaunchWeb.{CoveredCallsLive, OnchainSteps, ReadFailedError}

  @moduletag :capture_log
  @ens "account_ens_identities"
  @ticket "/stock/covered-call?listing=1"
  # The page's book is read in the background; a loaded machine can take longer
  # than LiveViewTest's 100 ms.
  @async_ms 2_000

  # The account's wallets are read once the page has mounted (the panel's first
  # update), and that read loses its connection, as when one pooled connection
  # is lost and the page's own read just before it was not.
  defp lose_wallet_reads_after_mount(view_module) do
    handler = "lose-after-mount-#{inspect(self())}"

    :telemetry.attach(
      handler,
      [:phoenix, :live_view, :mount, :stop],
      fn _event, _measurements, %{socket: socket}, _config ->
        if socket.view == view_module and Phoenix.LiveView.connected?(socket) do
          :telemetry.detach(handler)
          lose_reads_of(@ens)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp signed_in(conn, account) do
    session = signed_in_session(account.id)

    conn
    |> Phoenix.ConnTest.init_test_session(session)
    |> connects_with(session)
    |> live(@ticket)
  end

  test "WALLETS_UNREAD_SAY_TRY_AGAIN: a wallet panel whose wallets can't be read sends nothing and never asks to sign in",
       %{conn: conn} do
    CoveredCallsChain.install()
    account = TestSupport.register_creator!()
    lose_wallet_reads_after_mount(CoveredCallsLive)

    {:ok, view, _html} = signed_in(conn, account)
    render_async(view, @async_ms)

    # The person's own wallet is the one open in their wallet app.
    view
    |> with_target("#covered-call-fill-1")
    |> render_hook("onchain_active_wallet", %{"address" => account.wallet_address})

    view |> element("#covered-call-buy-1-form") |> render_change(%{"amount" => "1"})
    view |> element("#covered-call-fill-1-review") |> render_click()

    # No review, so no step, ever reaches the wallet.
    refute_push_event(view, "onchain-steps:review", %{review: %{}})
    assert has_element?(view, "#covered-call-fill-1-review-panel[hidden]")

    # The press says to try again, nothing on the page asks the person to sign
    # in, and the page still shows them signed in.
    assert has_element?(view, "#covered-call-fill-1-notice", OnchainSteps.unsent_note())
    refute has_element?(view, "[data-account-target=sign-in]")
    assert has_element?(view, ~s([data-account-target="profile"]))
  end

  test "a wallet read that fails for any other reason is a real error", %{conn: conn} do
    CoveredCallsChain.install()
    account = TestSupport.register_creator!()
    handler = "fail-wallet-read-#{inspect(self())}"

    # Only the wallet panel's own read of the account fails, and not as a lost
    # connection: renamed for this case's sandboxed transaction, 42P01.
    :telemetry.attach(
      handler,
      [:ash, :accounts, :read, :start],
      fn _event, _measurements, %{resource: resource}, _config ->
        {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

        if resource == Autolaunch.Accounts.HumanAccount and
             Enum.any?(stack, &match?({OnchainSteps, :adopt, _arity, _location}, &1)) do
          :telemetry.detach(handler)
          Repo.query!(~s|ALTER TABLE autolaunch_app.#{@ens} RENAME TO #{@ens}_unread|)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The ticket raising is what ends the page, reported here.
    test = self()
    raised = "ticket-raised-#{inspect(self())}"

    :telemetry.attach(
      raised,
      [:phoenix, :live_component, :update, :exception],
      fn _event, _measurements, %{kind: :error, reason: reason}, _config ->
        send(test, {:ticket_raised, reason})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(raised) end)

    # The ticket, and so its read of the account, comes once the page's book is
    # read in the background, so the page ends while it is still opening or just
    # after it opened; which one depends on how fast the book is read.
    Process.flag(:trap_exit, true)

    try do
      signed_in(conn, account)
    catch
      :exit, _page_ended_while_opening -> :ok
    end

    assert_receive {:ticket_raised, %ReadFailedError{}}, @async_ms
  end

  test "CONNECT_ENS_UNREAD_SAYS_TRY_AGAIN: Connect ENS with an unreadable sign-in says try again" do
    account = TestSupport.register_creator!()
    lose_reads_of(@ens)

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :name, message: message}]}} =
             Accounts.connect_ens("someone.eth", leased(account.id))

    assert message =~ "Try again"
  end

  test "ENS_NAME_TAKEN_IS_NOT_TRY_AGAIN: a name another account holds is refused for good, not retried" do
    holder = TestSupport.register_creator!()
    account = TestSupport.register_creator!()
    name = "taken-#{Elixir.System.unique_integer([:positive])}.eth"

    {:ok, _held} =
      Accounts.upsert_linked_identity(:ens, name, name, name, DateTime.utc_now(), %{}, holder.id,
        actor: %System{}
      )

    lease = current_lease(account.id)

    details = %{
      normalized_name: name,
      manager: account.wallet_address,
      eth_address: account.wallet_address,
      resolver_address: "0x" <> String.duplicate("0", 40)
    }

    assert ConnectEns.record_name(lease.lineage, account.id, details) == {:error, :name_taken}
  end
end
