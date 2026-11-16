defmodule AutolaunchWeb.EarnAgentController do
  @moduledoc """
  Earn for a signed, paired agent, acting for the person it is paired with:
  the preview of a deposit or withdrawal, its wallet steps, and the balance in
  each product. The verified request names the agent and so the account
  (`AutolaunchWeb.Plugs.AgentAccess`); a signer named in the body is used only
  when it is one of that account's own wallets, and with none named the
  account's signed-in wallet is used. The site only prepares the steps: the
  wallet's own key signs and sends each one.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Earn
  alias AutolaunchWeb.EarnAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def quote(conn, _params), do: run(conn, &Earn.earn_quote/4)
  def prepare(conn, _params), do: run(conn, &Earn.prepare_earn/4)

  def positions(conn, _params),
    do: Answer.send(conn, Earn.earn_positions(actor: conn.assigns.actor))

  defp run(conn, operation) do
    case Answer.input(conn.body_params) do
      {:ok, product, kind, input} ->
        Answer.send(conn, operation.(product, kind, input, actor: conn.assigns.actor))

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end
end
