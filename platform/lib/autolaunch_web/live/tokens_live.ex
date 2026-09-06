defmodule AutolaunchWeb.TokensLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok,
     assign_async(socket, [:records, :creators], fn ->
       read_index(&Autolaunch.list_tokens/0)
     end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.collection kind={:tokens} records={@records} creators={@creators} />
    """
  end
end
