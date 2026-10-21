defmodule AutolaunchWeb.PublicPagesHTML do
  use AutolaunchWeb, :html

  # The developer guide opens the list of tools agents see, as the footer does.
  def show(assigns) do
    ~H"""
    <div class="fact-page document-page">
      <AutolaunchWeb.Components.AgentTools.button
        :if={@conn.request_path == "/docs"}
        id="docs-agent-tools-button"
        dialog="shell-agent-tools"
      />
      {@document}
    </div>
    """
  end
end
