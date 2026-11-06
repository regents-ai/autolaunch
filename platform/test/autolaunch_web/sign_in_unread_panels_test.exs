defmodule AutolaunchWeb.SignInUnreadPanelsTest do
  @moduledoc """
  Connect ENS follows the same rule as a page (`AutolaunchWeb.ReadFailure`): when
  the signed-in account can't be read because the connection was lost, it says
  to try again and never to sign in; a name another account holds is refused for
  good, not a try-again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults

  alias Autolaunch.{Accounts, TestSupport}
  alias Autolaunch.Accounts.ConnectEns
  alias Autolaunch.Actors.System

  @moduletag :capture_log
  @ens "account_ens_identities"

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
