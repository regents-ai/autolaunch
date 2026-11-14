defmodule AutolaunchWeb.ExposureAgentController do
  @moduledoc """
  Exposure for a signed, paired agent, acting for the person it is paired
  with: their holding for one week, and the wallet steps for one action on it.
  The verified request names the agent and so the account
  (`AutolaunchWeb.Plugs.AgentAccess`); a signer named in the body is used only
  when it is one of that account's own wallets, and with none named the
  account's signed-in wallet is used. The site only prepares the steps: the
  wallet's own key signs and sends each one.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Exposure
  alias AutolaunchWeb.ExposureAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def holdings(conn, %{"week" => week}) do
    actor = conn.assigns.actor
    Answer.send(conn, Exposure.exposure_holdings(week, actor: actor), :holdings)
  end

  def prepare(conn, %{"week" => week}) do
    case Answer.prepare_input(conn.body_params) do
      {:ok, input} ->
        kind = conn.body_params["kind"]
        result = Exposure.prepare_exposure(week, kind, input, actor: conn.assigns.actor)
        Answer.send(conn, result, :prepare)

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end
end
