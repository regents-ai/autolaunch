defmodule AutolaunchWeb.VisitLog do
  @moduledoc """
  One log line for each thing a person or agent did, what the site did about it
  and how it ended, so a visit can be replayed from the lines (the plan is
  ash-template's docs/logging-replay-plan.md).

  Every line carries the same few fields and nothing else: in production the
  JSON formatter writes only the `visit`, `actor`, `surface`, `request_id` and
  `event` metadata (config/runtime.exs), and `record/4` keeps only an event's
  name, where it happened, its outcome and how long it took. Free text never
  reaches a line: names, routes and tool names come from the site's own code or
  from a short header checked against a pattern, and anything else is written as
  `other`.

  - `visit`: a random id for one browser visit, kept in the `_visit` cookie until
    the browser closes and sent by the page's own scripts in `x-regent-visit`
    when they send no cookies. It is not tied to the account. Calls from outside
    a page have none.
  - `actor`: `person:` or `agent:` and a one-way code for the account or agent,
    or `anonymous`. The code cannot be turned back into the account.
  - `surface`: `page`, `webmcp`, `cli`, `agent_http` or `job`. The page's tools
    say `x-regent-client: webmcp/<tool>`; Regents CLI says
    `regents-cli/<version> <command>`. An API call that names neither but
    carries a visit is the page's own script, so it is `page`.

  The events themselves come from `AutolaunchWeb.VisitLog.Events`; the browser
  adds the few only it can see through `AutolaunchWeb.VisitLogController`.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  @cookie "_visit"
  @visit ~r/\A[A-Za-z0-9_-]{22}\z/
  @webmcp ~r/\Awebmcp\/([a-z][a-z0-9_]{0,63})\z/
  @cli ~r/\Aregents-cli\/([0-9A-Za-z.+-]{1,32}) ([a-z0-9][a-z0-9 _-]{0,63})\z/
  @where ~r/\A[A-Za-z0-9_.:\/@* -]{1,120}\z/
  @outcome ~r/\A[a-z0-9_]{1,48}\z/
  @names ~w(request tool.call page press action job outgoing page.error tool.unsent press.unsent)

  @doc "The metadata a production line carries (config/runtime.exs)."
  def fields, do: [:request_id, :visit, :actor, :surface, :event]

  @doc "Writes one event line (`event/4`); its message is its name, where and outcome."
  def record(name, where, outcome \\ nil, ms \\ nil) do
    event = event(name, where, outcome, ms)
    message = Enum.join([event.name, event.where | List.wrap(event[:outcome])], " ")
    Logger.info(fn -> {message, event: event} end)
  end

  @doc """
  One event. `where` and `outcome` that do not fit their pattern are written as
  `other`; `ms` is a whole number of milliseconds or left out.
  """
  def event(name, where, outcome, ms) when name in @names do
    %{name: name, where: fit(where, @where), outcome: outcome && fit(outcome, @outcome), ms: ms}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fit(value, pattern) when is_binary(value),
    do: if(Regex.match?(pattern, value), do: value, else: "other")

  defp fit(value, pattern) when is_atom(value), do: fit(Atom.to_string(value), pattern)
  defp fit(_value, _pattern), do: "other"

  @doc "The one-way code for who acted: an account, a signed-in agent, or nobody."
  # An agent is known here by its wallet (Autolaunch.Agents.resolve/1).
  def actor(%Autolaunch.Actors.Agent{wallet_address: wallet}),
    do: "agent:" <> code(String.downcase(wallet))

  def actor(%Autolaunch.Accounts.HumanAccount{id: id}), do: "person:" <> code(id)
  def actor(%Autolaunch.AccessContext{principal: {:human, account}}), do: actor(account)
  def actor(_nobody), do: "anonymous"

  defp code(id) do
    :crypto.mac(:hmac, :sha256, key(), to_string(id))
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  # Derived from the endpoint's secret, so the codes cannot be recomputed from
  # account ids without it, and stay the same across machines and releases.
  defp key do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        key =
          AutolaunchWeb.Endpoint.config(:secret_key_base)
          |> Plug.Crypto.KeyGenerator.generate("visit log actor", length: 32)

        :persistent_term.put(__MODULE__, key)
        key

      key ->
        key
    end
  end

  @doc "Where a request or page lands, as its route (`/auctions/:symbol/:tail`), never its own path."
  def route(router, method, path, host) do
    case Phoenix.Router.route_info(router, method, path, host) do
      %{route: route} -> route
      :error -> "unmatched"
    end
  end

  @doc "Short module names: `AuctionsLive`, not `AutolaunchWeb.AuctionsLive`."
  def short(module) when is_atom(module), do: module |> inspect() |> short()

  def short(name) when is_binary(name),
    do:
      name
      |> String.replace_prefix("AutolaunchWeb.", "")
      |> String.replace_prefix("Autolaunch.", "")

  # Plug: every request through the endpoint, before the router.

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    {surface, client} = surface(conn)
    {conn, visit} = visit(conn, surface)
    surface = if surface == "agent_http" and visit, do: "page", else: surface
    Logger.metadata(visit: visit, surface: surface)

    conn
    |> assign(:visit, visit)
    |> put_private(:visit_log_client, client)
  end

  # A page keeps its cookie's visit, and a page opened without one starts a visit.
  # An API call takes the visit its page's script sent, in the header when it
  # sends no cookies, or in the cookie when it does.
  defp visit(conn, "page") do
    case conn.cookies[@cookie] do
      visit when is_binary(visit) ->
        if Regex.match?(@visit, visit), do: {conn, visit}, else: start(conn)

      nil ->
        if page?(conn), do: start(conn), else: {conn, nil}
    end
  end

  defp visit(conn, _surface) do
    sent = get_req_header(conn, "x-regent-visit") ++ List.wrap(conn.cookies[@cookie])
    {conn, Enum.find(sent, &Regex.match?(@visit, &1))}
  end

  defp start(conn) do
    visit = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn =
      put_resp_cookie(conn, @cookie, visit,
        http_only: true,
        same_site: "Lax",
        secure: conn.scheme == :https
      )

    {conn, visit}
  end

  # Only a browser opening a page asks for HTML; health checks and API calls don't.
  defp page?(conn),
    do: conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/html"))

  defp surface(%Plug.Conn{path_info: ["api" | _]} = conn) do
    client = conn |> get_req_header("x-regent-client") |> List.first("")

    cond do
      match = Regex.run(@webmcp, client) -> {"webmcp", Enum.at(match, 1)}
      match = Regex.run(@cli, client) -> {"cli", "#{Enum.at(match, 2)}@#{Enum.at(match, 1)}"}
      true -> {"agent_http", nil}
    end
  end

  defp surface(_conn), do: {"page", nil}

  @doc "The tool or command the caller named in `x-regent-client`, if any."
  def client(conn), do: conn.private[:visit_log_client]

  # on_mount, for every LiveView (AutolaunchWeb.live_view/0). The connected page
  # runs in its own process, so it takes the visit its first render passed on
  # (AutolaunchWeb.Live.Session.render_context/1).
  def on_mount(:default, _params, session, socket) do
    visit = session["visit"]
    Logger.metadata(visit: visit, surface: "page", actor: actor(socket.assigns[:access_context]))
    {:cont, Phoenix.Component.assign(socket, :visit, visit)}
  end
end
