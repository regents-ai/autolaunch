defmodule AutolaunchWeb.AgentBidController do
  @moduledoc """
  Bids on Base auctions for a signed, paired agent, acting for the person it is
  paired with: the wallet steps of one bid, and of one of the person's own bids'
  return and claim. The verified request names the agent and so the account
  (`AutolaunchWeb.Plugs.AgentAccess`); a signer named in the body is used only
  when it is one of that account's own wallets, and with none named the
  account's signed-in wallet is used. The site only prepares the steps: the
  wallet's own key signs and sends each one (`Autolaunch.AgentBid`).
  """

  use AutolaunchWeb, :controller

  alias AutolaunchWeb.AgentBidAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def prepare(conn, _params) do
    case Answer.input(:prepare, conn.body_params) do
      {:ok, input} -> Answer.send(conn, Autolaunch.prepare_bid(input, actor: conn.assigns.actor))
      :error -> Answer.refuse(conn, :invalid_request)
    end
  end

  def settle(conn, %{"bid" => bid}) do
    case Answer.input(:settle, conn.body_params) do
      {:ok, input} ->
        Answer.send(
          conn,
          Autolaunch.prepare_bid_settlement(Map.put(input, "bid", bid),
            actor: conn.assigns.actor
          )
        )

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end
end
