defmodule AutolaunchWeb.SignInUnreadPanelsTest do
  @moduledoc """
  A panel whose signed-in account could not be read just now says to try again,
  never to sign in: a wallet panel holds its wallets as unread, and Connect ENS
  answers "That did not go through. Try again in a moment." instead of saying
  the name doesn't fit.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.DatabaseFaults
  import ExUnit.CaptureLog

  alias Autolaunch.{Accounts, TestSupport}
  alias AutolaunchWeb.OnchainSteps

  @moduletag :capture_log
  @ens "account_ens_identities"
  @again "That did not go through. Try again in a moment."

  test "WALLETS_UNREAD_SAY_TRY_AGAIN: a wallet panel whose wallets can't be read asks to try again" do
    account = TestSupport.register_creator!()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        session_lease: current_lease(account.id),
        current_human_id: account.id
      }
    }

    lose_reads_of(@ens)
    {socket, log} = with_log(fn -> OnchainSteps.adopt(socket) end)

    assert socket.assigns.linked == :unread
    assert log =~ "sign-in read connection_lost: "
    assert OnchainSteps.signer(:unread, account.wallet_address) == nil

    for reason <- ["wallet_unavailable", "step_unknown"],
        do: assert(OnchainSteps.failure_note(reason, :unread, nil, "Base") == @again)

    # Read again on the next update, once the wallets read.
    restore_reads_of(@ens)
    assert OnchainSteps.adopt(socket).assigns.linked == [String.downcase(account.wallet_address)]
  end

  test "CONNECT_ENS_UNREAD_SAYS_TRY_AGAIN: Connect ENS with an unreadable sign-in says try again" do
    account = TestSupport.register_creator!()
    lose_reads_of(@ens)

    assert {:error, error} = Accounts.connect_ens("someone.eth", leased(account.id))
    assert Exception.message(error) =~ @again
  end
end
