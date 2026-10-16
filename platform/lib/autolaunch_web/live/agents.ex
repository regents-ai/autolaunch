defmodule AutolaunchWeb.Live.Agents do
  @moduledoc """
  The pairing box on screen (`AutolaunchWeb.PairingBox`) hears when an agent
  pairs, checks in or is unpaired on any Regent site (`RegentAgents.topic/1`,
  which `RegentAgents.Listener` feeds), as the template's shell does, so a code
  on screen gives way to the agent that used it. It is the side panel's box
  (`shell-pairing-box`) on every LiveView page but Account, which has its own
  and reads its agents again (`AutolaunchWeb.AccountLive.agents_changed/1`).

  It runs after the session hook, so it listens for the account the mount
  proved, and the session hook re-reads the sign-in before each change lands
  here.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias AutolaunchWeb.{AccountLive, PairingBox}

  def on_mount(:agents, _params, _session, socket) do
    {:cont,
     socket
     |> listen()
     |> attach_hook(:agents_changed, :handle_info, fn
       :agents_changed, socket -> {:halt, changed(socket)}
       _message, socket -> {:cont, socket}
     end)}
  end

  defp listen(socket) do
    with true <- connected?(socket),
         {:human, account} <- socket.assigns.access_context.principal do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, RegentAgents.topic(account.privy_user_id))
    end

    socket
  end

  defp changed(%{view: AccountLive} = socket), do: AccountLive.agents_changed(socket)

  defp changed(socket) do
    send_update(PairingBox, id: "shell-pairing-box", agents_changed: true)
    socket
  end
end
