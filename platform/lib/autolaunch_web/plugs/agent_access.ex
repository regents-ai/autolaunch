defmodule AutolaunchWeb.Plugs.AgentAccess do
  @moduledoc "Exact SIWA proof and current pairing, independent of browser owner credentials."
  @behaviour Plug
  import Plug.Conn
  alias AutolaunchWeb.ApiError
  def init(opts), do: opts

  def call(%{method: method} = conn, _opts) when method in ["POST", "PATCH", "PUT"] do
    case get_req_header(conn, "content-type") do
      ["application/json" <> _] ->
        authenticate(conn)

      _ ->
        refuse(
          conn,
          :unprocessable_entity,
          "invalid_request",
          "Send signed application/json bytes."
        )
    end
  end

  def call(conn, _opts), do: authenticate(conn)

  defp authenticate(conn) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    conn =
      if conn.assigns[:raw_body] == "",
        do: %{conn | assigns: Map.delete(conn.assigns, :raw_body)},
        else: conn

    conn =
      Siwa.AgentAuthPlug.call(conn,
        client: RegentAgents.Broker,
        hooks: RegentAgents.HTTP.Hooks,
        audience: "autolaunch"
      )

    case conn.assigns do
      %{regent_agent: agent} ->
        resolve(conn, agent.wallet)

      %{regent_agent_refusal: %{reason: :siwa_request_failed}} ->
        refuse(
          conn,
          :service_unavailable,
          "siwa_unavailable",
          "The signing service is unavailable."
        )

      _ ->
        refuse(
          conn,
          :unauthorized,
          "signed_proof_required",
          "Send fresh SIWA proof for this exact request."
        )
    end
  end

  defp resolve(conn, wallet) do
    case Autolaunch.Agents.resolve(wallet) do
      {:ok, actor, account} ->
        conn |> assign(:actor, actor) |> assign(:agent_owner_account, account)

      {:error, :not_paired} ->
        refuse(
          conn,
          :forbidden,
          "agent_not_paired",
          "Pair this named agent with your account before private work."
        )

      {:error, :owner_not_local} ->
        refuse(
          conn,
          :forbidden,
          "owner_not_local",
          "The owner must sign in to Autolaunch to establish verified account access."
        )

      _ ->
        refuse(
          conn,
          :service_unavailable,
          "account_unavailable",
          "Account access is unavailable."
        )
    end
  end

  defp refuse(conn, status, code, message),
    do: conn |> ApiError.send(status, code, message) |> halt()
end
