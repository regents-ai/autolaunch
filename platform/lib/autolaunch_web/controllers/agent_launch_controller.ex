defmodule AutolaunchWeb.AgentLaunchController do
  @moduledoc """
  Launches for a signed, paired agent, acting for the person it is paired
  with: the launch step of one of the person's saved drafts. The verified
  request names the agent and so the account
  (`AutolaunchWeb.Plugs.AgentAccess`); a signer named in the body is used only
  when it is one of that account's own wallets, and with none named the
  account's signed-in wallet is used. The site only prepares the step: the
  wallet's own key signs and sends it (`Autolaunch.AgentLaunch`).
  """

  use AutolaunchWeb, :controller

  alias AutolaunchWeb.AgentLaunchAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def prepare(conn, %{"draft" => draft}) do
    case Answer.input(conn.body_params) do
      {:ok, input} ->
        Answer.send(
          conn,
          Autolaunch.prepare_launch(Map.put(input, "draft", draft), actor: conn.assigns.actor)
        )

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end
end
