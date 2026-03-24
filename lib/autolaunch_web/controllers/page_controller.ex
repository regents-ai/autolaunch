defmodule AutolaunchWeb.PageController do
  use AutolaunchWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/auctions/how-it-works")
  end
end
