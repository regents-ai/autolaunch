defmodule AutolaunchWeb.PageController do
  use AutolaunchWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
