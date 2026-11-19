defmodule AutolaunchWeb.Prelaunch do
  @moduledoc "Prelaunch HTTP and LiveView admission, before uploads or write-capable mounts. Accounts stay open."
  @behaviour Plug
  import Plug.Conn
  alias Autolaunch.Prelaunch

  @opens_soon "Autolaunch opens soon."

  @read_events %{
    AutolaunchWeb.HomeLive => ~w(filter retry retry_calls load-more),
    AutolaunchWeb.AuctionsLive => ~w(retry),
    AutolaunchWeb.TokensLive => ~w(retry),
    AutolaunchWeb.AuctionLive => ~w(retry),
    AutolaunchWeb.TokenLive => ~w(retry),
    AutolaunchWeb.PortfolioLive => ~w(refresh),
    # Accounts stay open: the Account page reads its connections again once
    # the browser has connected or disconnected an X account.
    AutolaunchWeb.AccountLive => ~w(refresh_x_connections),
    AutolaunchWeb.CoveredCallsLive =>
      ~w(refresh sell sell_expiry sell_strike sell_suggested bid bid_expiry bid_strike bid_suggested buy sale mode dismiss_done),
    AutolaunchWeb.ExposureLive => ~w(refresh tab leg dismiss_done),
    AutolaunchWeb.EarnLive => ~w(refresh dismiss_done),
    AutolaunchWeb.UpcomingLive => ~w(filter)
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Router path matching decodes segments; the admission check must do so too.
    path = Enum.map(conn.path_info, &URI.decode/1)

    cond do
      not Prelaunch.read_only?() -> conn
      match?([page | _] when page in ["create", "agent-business"], path) -> refuse(conn, 404)
      open?(conn.method, path) -> conn
      true -> refuse(conn, 503)
    end
  end

  @doc """
  Whether a request with `method` to `path`, its decoded segments, is served in
  read-only mode; the create pages are closed besides. The guides' Agent access
  table asks it of each action's route (`AutolaunchWeb.PublicDocuments`).
  """
  def open?(method, path),
    do:
      account_path?(path) or visit_report?(method, path) or
        signed_account_request?(method, path) or method in ["GET", "HEAD"] or
        public_quote?(method, path)

  @doc """
  What a request this plug refuses in read-only mode is answered with, in JSON
  with its hint (`AutolaunchWeb.ApiError.body/2`). A launch draft save's hosted
  MCP tool, which this plug does not reach, answers the same
  (`Autolaunch.AgentAccount`).
  """
  def refusal,
    do: AutolaunchWeb.Refusal.new(:service_unavailable, "prelaunch_read_only", @opens_soon)

  # Sign-in, sign-out, profile editing and connecting an app such as Claude
  # (`AutolaunchWeb.OAuthController`) work before opening. So does the hosted MCP
  # server's address, and anything but POST /mcp is refused there
  # (`AutolaunchWeb.Plugs.McpAgent`). Its tools that read, or keep a connected
  # app's identity and pairing, work in read-only mode; the ones that prepare
  # wallet steps (`prepare_covered_call`, `prepare_earn`) are neither listed nor
  # run while it is on, by their actions' own policy
  # (`Autolaunch.CoveredCalls.Checks.LaunchesOpen`), and a launch draft save
  # refuses as its route does (`refusal/0`).
  defp account_path?(["auth" | _]), do: true
  defp account_path?(["oauth" | _]), do: true
  defp account_path?(["mcp" | _]), do: true
  defp account_path?(["api", "v1", "profile" | _]), do: true
  defp account_path?(_), do: false

  # The browser's visit reports only write log lines (AutolaunchWeb.VisitLogController).
  defp visit_report?("POST", ["visit-log"]), do: true
  defp visit_report?(_, _), do: false

  # Pairing is account access.
  # Metadata and all launch/wallet writes retain the prelaunch refusal, and so
  # does preparing covered-call steps, as preparing any wallet step on a page does.
  defp signed_account_request?("POST", ["api", "agents", "v1", "pair"]), do: true

  defp signed_account_request?(_, _), do: false

  # These POSTs only calculate a quote: a bid's from stored public data,
  # while covered calls are on a covered call's suggested premium from the
  # chain's reference price, and while Earn is on a deposit's or withdrawal's
  # preview. Off, each address is refused like any other POST.
  defp public_quote?("POST", ["api", "v1", "auctions", _id, "bid-quote"]), do: true

  defp public_quote?("POST", ["api", "v1", "covered-calls", _symbol, "quote"]),
    do: Autolaunch.CoveredCalls.Deployment.enabled?()

  # While Earn is on, an agent's preview of a deposit or withdrawal only reads
  # the chain; its steps wait for the site to open like every other.
  defp public_quote?("POST", ["api", "agent", "v1", "earn", "quote"]),
    do: Autolaunch.Earn.Catalog.enabled?()

  defp public_quote?(_, _), do: false

  # The response type and body are fixed here (a JSON error or the rendered
  # error page); neither comes from the request.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp refuse(conn, status) do
    json? =
      match?(["api" | _], conn.path_info) or
        Enum.any?(get_req_header(conn, "accept"), &String.contains?(&1, "application/json"))

    {type, body} =
      if json? do
        %AutolaunchWeb.Refusal{code: code, message: message} = refusal()
        {"application/json", Jason.encode!(AutolaunchWeb.ApiError.body(code, message))}
      else
        {"text/html",
         AutolaunchWeb.ErrorHTML.render("#{status}.html", %{conn: conn})
         |> Phoenix.HTML.Safe.to_iodata()}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(type)
    |> send_resp(status, if(conn.method == "HEAD", do: "", else: body))
    |> halt()
  end

  # An old signed LiveView token must not resurrect a create page over the socket.
  # Write-capable LiveComponents are not mounted at all during prelaunch.
  def on_mount(:default, _params, _session, socket) do
    cond do
      not Prelaunch.read_only?() ->
        {:cont, socket}

      socket.view in [AutolaunchWeb.StocksCreateLive, AutolaunchWeb.CreateLive] ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      true ->
        {:cont,
         Phoenix.LiveView.attach_hook(socket, :prelaunch_read_only, :handle_event, fn event,
                                                                                      _params,
                                                                                      socket ->
           if event in Map.get(@read_events, socket.view, []),
             do: {:cont, socket},
             else: {:halt, socket}
         end)}
    end
  end
end
