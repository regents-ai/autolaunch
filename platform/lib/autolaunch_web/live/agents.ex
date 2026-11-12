defmodule AutolaunchWeb.Live.Agents do
  @moduledoc """
  The account menu's agents (`AutolaunchWeb.MenuAgents`) and the pairing window's
  box (`AutolaunchWeb.PairingBox`) hear when an agent pairs, checks in or is
  unpaired on any Regent site (`RegentAgents.topic/1`, which
  `RegentAgents.Listener` feeds), as the template's shell does, on every LiveView
  page, so a code on screen gives way to the agent that used it. The Agents page
  reads its agents again (`AutolaunchWeb.AccountAgentsLive.read_agents/1`), and
  the pairing link's page updates its own box.

  It runs after the session hook, so it listens for the account the mount
  proved, and the session hook re-reads the sign-in before each change lands
  here.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias AutolaunchWeb.{AccountAgentsLive, MenuAgents, PairingBox, PairLive, PairWindowLive}

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

  # The window's box on a page drawn without LiveView is the only one there.
  defp changed(%{view: PairWindowLive} = socket) do
    send_update(PairingBox, id: "shell-pairing-box", agents_changed: true)
    socket
  end

  defp changed(socket) do
    send_update(MenuAgents, id: "shell-agents", agents_changed: true)
    send_update(PairingBox, id: "shell-pairing-box", agents_changed: true)

    case socket.view do
      AccountAgentsLive ->
        AccountAgentsLive.read_agents(socket)

      PairLive ->
        send_update(PairingBox, id: "pair-pairing-box", agents_changed: true)
        socket

      _other ->
        socket
    end
  end
end
