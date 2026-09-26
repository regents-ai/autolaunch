defmodule AutolaunchWeb.ErrorMD do
  @moduledoc "The error page a request that asked for Markdown receives, with where to go instead."

  def render(template, _assigns) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> RegentAgentAccess.Recovery.markdown(AutolaunchWeb.PublicDocuments.recovery_links())
  end
end
