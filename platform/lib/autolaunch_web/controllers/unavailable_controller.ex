defmodule AutolaunchWeb.UnavailableController do
  @moduledoc """
  The page a visitor reaches when a page is not offered where they are. The
  site's edge sends them here instead of its own refusal, so they stay inside
  the product shell, with the top bar and rail, and can carry on.
  """
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.PublicDocuments

  plug AutolaunchWeb.Plugs.PageShell

  def show(conn, _params), do: render(conn, :show, PublicDocuments.page("/unavailable"))
end
