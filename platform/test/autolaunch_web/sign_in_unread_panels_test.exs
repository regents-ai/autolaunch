defmodule AutolaunchWeb.SignInUnreadPanelsTest do
  @moduledoc """
  A panel follows the same rule as a page (`AutolaunchWeb.ReadFailure`): when
  the signed-in account can't be read because the connection was lost, it says
  to try again and never to sign in, and sends nothing; any other failure is a
  real error. Connect ENS tells a name another account holds apart from a
  try-again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, Repo, TestSupport}
  alias Autolaunch.Accounts.ConnectEns
  alias Autolaunch.Actors.System
  alias AutolaunchWeb.{OnchainSteps, ReadFailedError}

  @moduletag :capture_log
  @ens "account_ens_identities"

  # The account's wallets are read once the page has mounted (the panels'
  # first update), and that read loses its connection, as when one pooled
  # connection is lost and the page's own read just before it was not.
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

  test "WALLETS_UNREAD_SAY_TRY_AGAIN: a wallet panel whose wallets can't be read sends nothing and never asks to sign in",
       %{conn: conn} do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)
    lose_wallet_reads_after_mount(AutolaunchWeb.AccountLive)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account")

    panel = with_target(view, "#credits-panel")
    # The person's own wallet is the one open in their wallet app.
    render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})

    for step <- ["approve", "buy"],
        do:
          render_hook(panel, "prepare_and_send", %{"form" => %{"amount" => "5"}, "step" => step})

    # No review, so no step, ever reaches the wallet.
    refute_push_event(view, "onchain-steps:review", %{review: %{}})

    render_hook(panel, "step_failed", %{"reason" => "wallet_unavailable"})
    note = view |> element("#credits-panel p[role=status]:not([hidden])") |> render()
    refute note =~ "Sign in"

    # The page still shows the person signed in.
    assert has_element?(view, ~s([data-account-target="profile"]))
  end

  test "a wallet read that fails for any other reason is a real error" do
    account = TestSupport.register_creator!()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        session_lease: current_lease(account.id),
        current_human_id: account.id
      }
    }

    # Renamed for this case's sandboxed transaction only: 42P01, not a lost connection.
    Repo.query!(~s|ALTER TABLE autolaunch_app.#{@ens} RENAME TO #{@ens}_unread|)
    assert_raise ReadFailedError, fn -> OnchainSteps.adopt(socket) end
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
