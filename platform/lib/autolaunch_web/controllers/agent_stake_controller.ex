defmodule AutolaunchWeb.AgentStakeController do
  @moduledoc """
  Staking on a launched token for a signed, paired agent, acting for the person
  it is paired with: the steps of one stake, unstake or claim on a token the
  site lists, named by its id as `autolaunch_tokens` lists it. The verified
  request names the agent and so the account (`AutolaunchWeb.Plugs.AgentAccess`);
  a signer named in the body is used only when it is one of that account's own
  wallets, and with none named the account's signed-in wallet is used. The site
  only prepares the steps: the wallet's own key signs and sends them
  (`Autolaunch.AgentStake`).
  """

  use AutolaunchWeb, :controller

  alias AutolaunchWeb.AgentStakeAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def prepare(conn, %{"token_id" => token_id}) do
    case Answer.input(conn.body_params) do
      {:ok, input} ->
        Answer.send(
          conn,
          Autolaunch.prepare_stake(Map.put(input, "token_id", token_id),
            actor: conn.assigns.actor
          )
        )

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end
end
