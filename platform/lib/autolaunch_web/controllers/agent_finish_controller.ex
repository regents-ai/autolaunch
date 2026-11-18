defmodule AutolaunchWeb.AgentFinishController do
  @moduledoc """
  Finishing an ended auction for a signed, paired agent, acting for the person
  it is paired with: the one finish step of an auction the site lists, named by
  its id as `autolaunch_auctions` lists it. The verified request names the
  agent and so the account (`AutolaunchWeb.Plugs.AgentAccess`); a signer named
  in the body is used only when it is one of that account's own wallets, and
  with none named the account's signed-in wallet is used. The site only
  prepares the step: the wallet's own key signs and sends it
  (`Autolaunch.AgentFinish`).
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.AgentFinish.Refused
  alias AutolaunchWeb.AgentFinishAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def prepare(conn, %{"auction_id" => auction_id}) do
    case Answer.input(conn.body_params) do
      {:ok, input} ->
        Answer.send(
          conn,
          Autolaunch.prepare_finish(Map.put(input, "auction_id", auction_id),
            actor: conn.assigns.actor
          )
        )

      :error ->
        Answer.refuse(conn, Refused.exception(reason: :invalid_request))
    end
  end
end
