defmodule AutolaunchWeb.ExposureAgentController do
  @moduledoc """
  Exposure for a signed, paired agent, acting for the person it is paired
  with: their holding of a series, and the wallet steps for one action. The
  verified request names the agent and so the account (`AutolaunchWeb.Plugs.AgentAccess`);
  a signer named in the body is used only when it is one of that account's own
  wallets, and with none named the account's signed-in wallet is used. The
  site only prepares the steps: the wallet's own key signs and sends each one.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Exposure
  alias AutolaunchWeb.{ApiError, Refusal}
  alias AutolaunchWeb.ExposureAnswer, as: Answer

  plug AutolaunchWeb.Plugs.AgentAccess

  def holdings(conn, %{"series" => series}) do
    actor = conn.assigns.actor
    Answer.send(conn, Exposure.exposure_holdings(series, actor: actor), :holdings)
  end

  def prepare(conn, %{"series" => series}) do
    case Answer.prepare_input(conn.body_params) do
      {:ok, input} ->
        kind = conn.body_params["kind"]

        series
        |> Exposure.prepare_exposure_answer(kind, input, actor: conn.assigns.actor)
        |> send_preparation(conn)

      :error ->
        Answer.refuse(conn, :invalid_request)
    end
  end

  defp send_preparation({:ok, data}, conn), do: ApiError.answer(conn, {:ok, %{data: data}})

  defp send_preparation({:error, %{errors: [%Refusal{} = refusal]}}, conn),
    do: ApiError.answer(conn, {:error, refusal})

  defp send_preparation({:error, %Ash.Error.Forbidden{}}, conn),
    do: ApiError.answer(conn, {:error, AutolaunchWeb.Prelaunch.refusal()})

  defp send_preparation({:error, %Ash.Error.Invalid{}}, conn),
    do: Answer.refuse(conn, :invalid_request)

  defp send_preparation({:error, error}, conn), do: Answer.send(conn, {:error, error}, :prepare)
end
