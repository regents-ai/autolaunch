defmodule AutolaunchWeb.AuctionsLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok, assign_async(socket, :records, fn -> read_index(&Autolaunch.list_auctions/0) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.collection kind={:auctions} records={@records} />
    """
  end
end
