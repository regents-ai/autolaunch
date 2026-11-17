defmodule AutolaunchWeb.AgentAccountController do
  @moduledoc """
  Signed private reads and launch draft edits; no wallet, signing or launch
  authority. Each answer is the one its hosted MCP tool gives too
  (`AutolaunchWeb.AccountAnswer`).
  """
  use AutolaunchWeb, :controller
  alias AutolaunchWeb.{AccountAnswer, ApiError}

  plug AutolaunchWeb.Plugs.AgentAccess

  def positions(conn, _params),
    do: ApiError.answer(conn, AccountAnswer.positions(conn.assigns.actor))

  def draft(conn, %{"kind" => kind}),
    do: ApiError.answer(conn, AccountAnswer.draft(kind, conn.assigns.actor))

  def save_draft(conn, %{"kind" => kind}),
    do:
      ApiError.answer(conn, AccountAnswer.save_draft(kind, conn.body_params, conn.assigns.actor))

  def points(conn, _params), do: ApiError.answer(conn, AccountAnswer.points(conn.assigns.actor))
end
