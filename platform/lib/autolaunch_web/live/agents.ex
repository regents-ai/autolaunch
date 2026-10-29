defmodule AutolaunchWeb.Live.Agents do
  @moduledoc """
  The account menu's agents (`AutolaunchWeb.MenuAgents`) hear when an agent
  pairs, checks in or is unpaired on any Regent site (`RegentAgents.topic/1`,
  which `RegentAgents.Listener` feeds), as the template's shell does, on every
  LiveView page. The Account page, which also holds the pairing box
  (`AutolaunchWeb.PairingBox`), reads its agents again too
  (`AutolaunchWeb.AccountLive.agents_changed/1`), so a code on screen gives way
  to the agent that used it.

  It runs after the session hook, so it listens for the account the mount
  proved, and the session hook re-reads the sign-in before each change lands
  here.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, send_update: 2]

  alias AutolaunchWeb.{AccountLive, MenuAgents}

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

  defp changed(socket) do
    send_update(MenuAgents, id: "shell-agents", agents_changed: true)
    if socket.view == AccountLive, do: AccountLive.agents_changed(socket), else: socket
  end
end
