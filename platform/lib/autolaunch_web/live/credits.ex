defmodule AutolaunchWeb.Live.Credits do
  @moduledoc """
  The signed-in person's Credits balance on every LiveView page, as
  `credits_read`, for the header's Credits button and the Buy Credits window
  behind it (`AutolaunchWeb.CreditsPanel`), as the template's shell does. It is
  read when the page connects and again whenever it changes on any Regent site
  (`RegentCredits.topic/1`). A page that shows more of the person's Credits
  than the balance defines `credits_changed/1`, which runs after each change.

  It runs after the session hook, so it reads for the account the mount proved,
  and the session hook re-reads the sign-in before each result lands here.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias AutolaunchWeb.Read

  def on_mount(:credits, _params, _session, socket) do
    {:cont,
     socket
     |> assign(credits_read: %Read{})
     |> listen()
     |> attach_hook(:credits_read, :handle_async, fn
       {Read, :credits_read, _generation} = name, result, socket ->
         {:halt, Read.settle(socket, name, result)}

       _name, _result, socket ->
         {:cont, socket}
     end)
     |> attach_hook(:credits_changed, :handle_info, fn
       :credits_changed, socket -> {:halt, changed(socket)}
       _message, socket -> {:cont, socket}
     end)}
  end

  # The first render shows a dash; the read starts once the page connects.
  defp listen(socket) do
    with true <- connected?(socket),
         {:human, account} <- socket.assigns.access_context.principal do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, RegentCredits.topic(account.privy_user_id))
      read(socket)
    else
      _not_yet -> socket
    end
  end

  defp changed(%{view: view} = socket) do
    socket = read(socket)

    if function_exported?(view, :credits_changed, 1),
      do: view.credits_changed(socket),
      else: socket
  end

  defp read(socket) do
    case socket.assigns.access_context.principal do
      {:human, account} ->
        Read.start(socket, :credits_read, account.privy_user_id, fn ->
          {:ok, RegentCredits.balance(account.privy_user_id)}
        end)

      _signed_out ->
        Read.clear(socket, :credits_read)
    end
  end
end
