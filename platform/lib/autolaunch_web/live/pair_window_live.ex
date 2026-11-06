defmodule AutolaunchWeb.PairWindowLive do
  @moduledoc """
  The pairing window's box on the pages the site draws without LiveView (the
  developer guide, About, the agent guides, the blog and the like), so Pair New
  Agent opens the same window over them as over every other page. The app layout
  renders it inside the window; on LiveView pages the layout holds the box itself.

  It signs in as the public root does (`AutolaunchWeb.Live.Session`), and an agent
  pairing anywhere (`AutolaunchWeb.Live.Agents`) names the agent that used a code
  on screen.
  """
  use Phoenix.LiveView, layout: false

  on_mount {AutolaunchWeb.Live.Session, :public_human}
  on_mount {AutolaunchWeb.Live.Agents, :agents}

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns) do
    ~H"""
    <.live_component
      :if={signed_in_account(@access_context)}
      module={AutolaunchWeb.PairingBox}
      id="shell-pairing-box"
      session_lease={@session_lease}
      account={signed_in_account(@access_context)}
    />
    """
  end

  defp signed_in_account(%{principal: {:human, account}}), do: account
  defp signed_in_account(_signed_out), do: nil
end
