defmodule AutolaunchWeb.Plugs.AgentAccess do
  @moduledoc """
  Exact SIWA proof and current pairing, independent of browser owner
  credentials. The agent acts for the account its pairing names
  (`Autolaunch.Agents.resolve/1`). On every signed route, as on the hosted MCP
  server, its pairing is checked again just before the answer leaves
  (`recheck_before_send/2`): when the pairing ended or changed hands while the
  request ran, the answer, a read or a save whose reply would carry the former
  person's data, is replaced with `agent_not_paired`, as the template's
  signed-agent plug does.
  """
  @behaviour Plug
  import Plug.Conn
  alias Autolaunch.Actors.Agent
  alias AutolaunchWeb.{ApiError, ReadFailure}

  @not_paired "Pair this named agent with your account before private work."
  @unavailable "Account access is unavailable."

  @sign_again "Sign the request with your agent key as https://siwa.regents.sh/skill.md describes, then send it again."
  @refusals %{
    duplicate_proof: {401, "A signature header was sent more than once.", @sign_again},
    unsupported_query: {401, "A signed request here takes no query string.", @sign_again},
    missing_signed_body:
      {401, "Send the body as JSON, signed with the rest of the request.", @sign_again},
    siwa_request_failed:
      {503, "The sign-in service could not be reached.", "Try again in a minute."},
    verification_failed: {401, "The signed agent request could not be verified.", @sign_again}
  }

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
      %{regent_agent: agent} -> resolve(conn, agent.wallet)
      %{regent_agent_refusal: refusal} -> refused(conn, refusal)
    end
  end

  # A refused signed request is answered as `RegentAgents.HTTP` answers one on
  # every site: the sign-in service's own status, code, message and hint when
  # it refused, and the shared plug's reason as the code when the plug did.
  defp refused(conn, %{
         siwa_status: status,
         siwa_code: code,
         siwa_message: message,
         siwa_hint: hint
       })
       when status in 400..599,
       do: answer(conn, status, %{code: code, message: message, hint: hint})

  defp refused(conn, %{siwa_status: status}) when status >= 500,
    do: named(conn, :siwa_request_failed)

  defp refused(conn, %{reason: :siwa_request_failed}), do: named(conn, :siwa_request_failed)
  defp refused(conn, %{source: :siwa_plug, reason: reason}), do: named(conn, reason)
  defp refused(conn, _refusal), do: named(conn, :verification_failed)

  defp named(conn, reason) do
    {status, message, hint} = Map.fetch!(@refusals, reason)
    answer(conn, status, %{code: Atom.to_string(reason), message: message, hint: hint})
  end

  defp answer(conn, status, error),
    do: conn |> put_status(status) |> Phoenix.Controller.json(%{error: error}) |> halt()

  defp resolve(conn, wallet) do
    case Autolaunch.Agents.resolve(wallet) do
      {:ok, actor, account} ->
        conn
        |> assign(:actor, actor)
        |> assign(:agent_owner_account, account)
        |> recheck_before_send(actor)

      {:error, :not_paired} ->
        refuse(conn, :forbidden, "agent_not_paired", @not_paired)

      _ ->
        refuse(conn, :service_unavailable, "account_unavailable", @unavailable)
    end
  end

  @doc """
  Checks a paired agent's pairing again just before the answer leaves, and
  replaces the answer when it has ended or changed hands meanwhile. The hosted
  MCP server uses it too, for a connected app calling as its paired identity
  (`AutolaunchWeb.Plugs.McpAgent`).
  """
  @spec recheck_before_send(Plug.Conn.t(), Agent.t()) :: Plug.Conn.t()
  def recheck_before_send(conn, %Agent{} = actor),
    do: register_before_send(conn, &recheck(&1, actor))

  # The request ran after the pairing was read. Before anything is sent, the
  # wallet's current pairing must still be this one, with the same person;
  # otherwise the answer is replaced, so an unpairing or a new pairing during
  # the request never sends the former person's data.
  defp recheck(conn, %Agent{} = actor) do
    case RegentAgents.Authority.resolve(Autolaunch.Repo, actor.wallet_address) do
      {:ok, %{id: id, privy_user_id: person}}
      when id == actor.pairing_id and person == actor.privy_user_id ->
        conn

      {:ok, _other_pairing} ->
        replace(conn, 403, ApiError.body("agent_not_paired", @not_paired))

      {:error, :not_paired} ->
        replace(conn, 403, ApiError.body("agent_not_paired", @not_paired))

      {:error, error} when conn.status in 200..299 ->
        ReadFailure.log("agent's pairing recheck", error)
        replace(conn, 503, ApiError.body("account_unavailable", @unavailable))

      {:error, _error} ->
        conn
    end
  end

  defp replace(conn, status, body) do
    %{conn | status: status, resp_body: Jason.encode_to_iodata!(body)}
    |> put_resp_content_type("application/json")
  end

  defp refuse(conn, status, code, message),
    do: conn |> ApiError.send(status, code, message) |> halt()
end
