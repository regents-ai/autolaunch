defmodule AutolaunchWeb.TreasuryController do
  use AutolaunchWeb, :controller

  alias AutolaunchWeb.{ApiError, MarketAnswer}

  # The answer is the one its hosted MCP tool gives too (`AutolaunchWeb.MarketAnswer`).
  def show(conn, params), do: ApiError.answer(conn, MarketAnswer.treasury(params))
end
