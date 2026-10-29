defmodule AutolaunchWeb.Plugs.McpAgent do
  @moduledoc """
  Admits a request to the hosted MCP server at `/mcp`, and says who is calling,
  before AshAi's router (`AshAi.Mcp.Router`) runs the tool, as the agent access
  spec (4.3) sets out. Cookies are never read.

  In order, before any credential is looked at:

  - a query string is refused (`unsupported_query`);
  - only `POST /mcp` is served: another method is refused with 405, another
    address under it with 404;
  - a page from another site (any `Origin` but this site's own, `null`
    included) is refused (`origin_not_allowed`); a request with no `Origin`, as
    MCP clients send, goes on;
  - a body that is not JSON is refused (`unsupported_media_type`), and so is a
    JSON-RPC batch (`batch_not_supported`): one call a request, so one signature
    covers one call.

  Then every request carries exactly one credential:

  - An agent's own signature (`Siwa.AgentAuthPlug.signed_request?/1`) is checked
    as on the agent routes (`AutolaunchWeb.Plugs.AgentAccess`, unchanged): the
    agent acts for the account its pairing names, and an agent no person paired
    is refused `agent_not_paired`, as everywhere on this site.
  - A connected app's token (`Authorization: Bearer`) must be one this site gave
    for its `/mcp` address with the identity permission, as `RegentOAuth`
    checks it, and spends its account's budget. While the app's own identity
    is paired with that account and the person allowed the agent permission
    (`Autolaunch.OAuth.agent_scope/0`), the actor is that paired agent, as an
    agent signing its own requests would be (`Autolaunch.Agents.resolve/1`,
    with the token's principal as its `connection`), so AshAi lists and runs
    the agent's tools under the same policies and its identity tools besides;
    its pairing is checked again before the answer leaves
    (`AgentAccess.recheck_before_send/2`). Otherwise the app is the actor
    (`Autolaunch.Actors.ConnectedApp`) and has its identity tools only. The
    budget is spent first. The identity's wallet is read once per account
    (`Autolaunch.Agents.HostedAddress`), so a call never waits on the sign-in
    service; while it can't be read the call is refused
    (`identity_unavailable`). Any other token is asked to connect again, with
    the `WWW-Authenticate` challenge naming this site's sign-in and both
    permissions. While connecting apps is off, a token is refused.
  - Both together are refused as `ambiguous_credentials`.
  - Neither is refused: while connecting apps is on, as `connection_required`
    with the challenge, so an app such as Claude starts its sign-in on its first
    request; while it is off, as `agent_auth_required`. Public reads are on the
    API and the browser tools.

  Each answer is private and never kept (`cache-control: private, no-store`).
  Refusals answer `{"error": {"code", "message", "hint"}}`, the site's one shape;
  what the tool itself refuses comes back as the tool's error, in the same shape
  (`AutolaunchWeb.ToolErrors`). Which way each request came in is counted as
  `[:autolaunch, :mcp, :auth]`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Autolaunch.Actors.{Agent, ConnectedApp}
  alias Autolaunch.Agents.HostedAddress
  alias AutolaunchWeb.Plugs.AgentAccess
  alias AutolaunchWeb.{PublicDocuments, ReadFailure}

  # 120 requests a minute for each connected account, after the endpoint's ceiling
  # for each address.
  @budget RegentAgentAccess.RateLimit.init(
            policy: "mcp",
            limit: 120,
            window: 60,
            admit: &Autolaunch.Accounts.RequestRateLimiter.admit/3,
            key: &__MODULE__.account/1
          )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Set as the answer leaves, so it holds whichever plug answers.
    conn = register_before_send(conn, &put_resp_header(&1, "cache-control", "private, no-store"))

    cond do
      conn.query_string != "" ->
        refuse(conn, :none, "unsupported_query")

      conn.path_info != ["mcp"] ->
        refuse(conn, :none, "not_found")

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> refuse(:none, "method_not_allowed")

      not own_origin?(conn) ->
        refuse(conn, :none, "origin_not_allowed")

      not json?(conn) ->
        refuse(conn, :none, "unsupported_media_type")

      is_list(conn.body_params["_json"]) ->
        refuse(conn, :none, "batch_not_supported")

      true ->
        caller(conn)
    end
  end

  @doc false
  def account(conn), do: Ash.PlugHelpers.get_actor(conn).principal.subject

  defp caller(conn) do
    case {Siwa.AgentAuthPlug.signed_request?(conn), get_req_header(conn, "authorization")} do
      {true, [_ | _]} -> refuse(conn, :both, "ambiguous_credentials")
      {true, []} -> agent(conn)
      {false, [_ | _] = token} -> connected_app(conn, token)
      {false, []} -> no_one(conn)
    end
  end

  defp own_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin == PublicDocuments.url("")
      _several -> false
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type] -> match?({:ok, "application", "json", _params}, Plug.Conn.Utils.content_type(type))
      _none_or_several -> false
    end
  end

  # The agent stays the request's `actor` assign too, which the visit log names
  # (`AutolaunchWeb.VisitLog`), as on the signed routes.
  defp agent(conn) do
    conn = AgentAccess.call(conn, [])

    if conn.halted do
      counted(conn, :siwa_request)
    else
      conn
      |> Ash.PlugHelpers.set_actor(conn.assigns.actor)
      |> counted(:siwa_request)
    end
  end

  defp connected_app(conn, token) do
    with true <- Autolaunch.OAuth.enabled?(),
         ["Bearer " <> bearer] <- token,
         {:ok, principal} <- RegentOAuth.verify(bearer, RegentOAuth.resource(), scope()) do
      conn
      |> Ash.PlugHelpers.set_actor(%ConnectedApp{principal: principal})
      |> RegentAgentAccess.RateLimit.call(@budget)
      |> as_paired_agent(principal)
      |> counted(:site_oauth)
    else
      false -> refuse(conn, :site_oauth, "delegated_access_not_enabled")
      _not_this_sites -> connect(conn, :site_oauth)
    end
  end

  # Within its account's budget, the app calls as its paired identity when the
  # person allowed it to work here as that agent; as itself otherwise. Only the
  # token's own account chooses the identity, and only a pairing with that same
  # account counts. An identity that can't be read is refused, never taken for
  # an unpaired one.
  defp as_paired_agent(%{halted: true} = conn, _principal), do: conn

  defp as_paired_agent(conn, %{subject: subject} = principal) do
    with true <- Autolaunch.OAuth.agent_scope() in principal.scopes,
         {:ok, address} <- HostedAddress.fetch(principal),
         {:ok, %Agent{privy_user_id: ^subject} = agent, _account} <-
           Autolaunch.Agents.resolve(address) do
      agent = %{agent | connection: principal}

      conn
      |> assign(:actor, agent)
      |> Ash.PlugHelpers.set_actor(agent)
      |> AgentAccess.recheck_before_send(agent)
    else
      false ->
        conn

      {:ok, _paired_with_another_account, _account} ->
        conn

      {:error, :not_paired} ->
        conn

      {:error, reason} when reason in [:unavailable, :account_unavailable] ->
        refusal(conn, "identity_unavailable")

      {:error, error} ->
        ReadFailure.log("connected app's agent read", error)
        refusal(conn, "identity_unavailable")
    end
  end

  defp no_one(conn) do
    if Autolaunch.OAuth.enabled?(),
      do: connect(conn, :none),
      else: refuse(conn, :none, "agent_auth_required")
  end

  defp connect(conn, mode) do
    conn
    |> put_resp_header(
      "www-authenticate",
      RegentOAuth.challenge(Enum.join(RegentOAuth.scopes(), " "))
    )
    |> refuse(mode, "connection_required")
  end

  defp scope, do: RegentMCPAgents.identity_scope()

  defp refuse(conn, mode, code), do: conn |> refusal(code) |> counted(mode)

  defp refusal(conn, code) do
    {status, message, hint} = words(code)

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: %{code: code, message: message, hint: hint}})
    |> halt()
  end

  defp words("unsupported_query"),
    do:
      {400, "The MCP address takes no query string.",
       "Send the same request to #{url()} with nothing after it. #{guide()}"}

  defp words("not_found"),
    do:
      {404, "There is nothing at this address.",
       "The hosted MCP server is at #{url()} alone. #{guide()}"}

  defp words("method_not_allowed"),
    do:
      {405, "The MCP address takes POST only.",
       "Send each JSON-RPC call as a POST to #{url()}. #{guide()}"}

  defp words("origin_not_allowed"),
    do:
      {403, "A page on another site can't call this server.",
       "Call it from your agent or app, not from a web page on another site. #{guide()}"}

  defp words("unsupported_media_type"),
    do:
      {415, "The MCP address takes a JSON body only.",
       "Send one JSON-RPC call with Content-Type: application/json. #{guide()}"}

  defp words("batch_not_supported"),
    do:
      {400, "Send one call a request.",
       "Send each call in its own request, each signed on its own, then send the request again. #{guide()}"}

  defp words("ambiguous_credentials"),
    do:
      {401, "Send your agent's signature or a connected app's token, not both.",
       "Leave out the Authorization header to call as your agent, or the signature headers to call as the connected app, then send the request again."}

  defp words("delegated_access_not_enabled"),
    do:
      {401, "This site doesn't take a connected app's token yet.",
       "Call as your agent instead: #{sign_in_how()}"}

  defp words("connection_required"),
    do:
      {401, "Connect this site, or sign the request as your agent.",
       "Add #{url()} to your app's connectors, such as Claude's, and approve it on this site, or #{sign_in_how()}"}

  defp words("identity_unavailable"),
    do:
      {503, "This connection's identity could not be read right now.",
       "Try again in a minute. #{guide()}"}

  defp words("agent_auth_required"),
    do: {401, "This server needs your agent's signature.", sign_in_how()}

  defp url, do: PublicDocuments.url("/mcp")

  defp guide, do: "The Hosted MCP section of #{PublicDocuments.url("/docs")} has the details."

  defp sign_in_how,
    do:
      "run regents mcp, which signs each call with your agent's wallet, or sign it yourself as the guide at #{PublicDocuments.url("/agents.md")} sets out, then send the request again."

  # Accepted, or refused here, by the agent's sign-in or by the account's budget.
  defp counted(conn, mode) do
    outcome = if conn.halted, do: :refused, else: :accepted
    :telemetry.execute([:autolaunch, :mcp, :auth], %{count: 1}, %{mode: mode, outcome: outcome})
    conn
  end
end
