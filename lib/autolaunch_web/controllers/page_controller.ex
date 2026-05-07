defmodule AutolaunchWeb.PageController do
  use AutolaunchWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/docs")
  end
end
