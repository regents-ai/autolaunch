defmodule AutolaunchWeb.MyPositionsController do
  @moduledoc """
  The signed-in wallet's own bids and launched tokens, for the page tool that
  reads them (`autolaunch_my_positions`). The verified session names the
  account and the one wallet it signed in with, and only that wallet is read
  (`AutolaunchWeb.AccountAnswer.positions/2`; a paired agent's route and hosted
  MCP tool read the same way, `positions/1`).
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Actors.Human
  alias AutolaunchWeb.{AccountAnswer, ApiError}

  def show(%{assigns: %{current_human_account: nil}} = conn, _params),
    do:
      ApiError.send(
        conn,
        :unauthorized,
        "authentication_required",
        "Nobody is signed in on this site in this browser."
      )

  def show(%{assigns: %{current_human_account: account}} = conn, _params) do
    actor = %Human{human_account_id: account.id}
    ApiError.answer(conn, AccountAnswer.positions(actor, account))
  end
end
