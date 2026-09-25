defmodule AutolaunchWeb.Metrics do
  @moduledoc """
  The metrics port's only page: `GET /metrics`, the site health set in
  Prometheus text format. It is served on its own port, apart from the site,
  so Fly's managed Prometheus can scrape it over the private network while the
  public site has no such page.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: "/metrics"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(AutolaunchWeb.Telemetry.reporter()))
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end
