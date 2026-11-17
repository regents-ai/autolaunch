defmodule AutolaunchWeb.TokenController do
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{ApiError, MarketAnswer}

  # Each answer is the one its hosted MCP tool gives too (`AutolaunchWeb.MarketAnswer`).
  def index(conn, params), do: ApiError.answer(conn, MarketAnswer.tokens(params))

  # The path names the token; a query string is refused, whatever it names.
  def show(conn, params) do
    conn = Plug.Conn.fetch_query_params(conn)

    if conn.query_params == %{},
      do: ApiError.answer(conn, MarketAnswer.token(params)),
      else: ApiError.answer(conn, MarketAnswer.invalid_query())
  end
end
