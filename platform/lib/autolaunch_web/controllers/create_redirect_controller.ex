defmodule AutolaunchWeb.CreateRedirectController do
  use AutolaunchWeb, :controller

  def stocks(conn, _params), do: redirect(conn, to: "/create?kind=stocks")
end
