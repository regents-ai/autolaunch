defmodule AutolaunchWeb.HealthController do
  @moduledoc """
  Whether the site and its own database answer: `/healthz` in plain text for the
  host's health check, `/api/v1/health` in JSON for the command line.
  """
  use AutolaunchWeb, :controller

  # A ready site names the commit it was built from, so a release check can see
  # which build is answering.
  def show(conn, _params) do
    {status, body} =
      if database_ready?(),
        do: {:ok, "ok " <> Application.fetch_env!(:autolaunch, :source_commit)},
        else: {:service_unavailable, "unavailable"}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  def status(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if database_ready?() do
      json(conn, %{status: "ok"})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{
        error: %{
          code: "unavailable",
          message: "The site is up but its database is not answering.",
          hint: "Try again in a minute."
        }
      })
    end
  end

  # Validate a real product read without returning user rows. The timeout is
  # below Fly's two-second health deadline, and no error/connection data leaves
  # this endpoint. A running BEAM alone does not make the application ready.
  # The prefix is the repository's own configured schema name, never request input.
  # sobelow_skip ["SQL.Query"]
  defp database_ready? do
    case Ecto.Adapters.SQL.query(
           Autolaunch.Repo,
           "SELECT 1 FROM \"#{Autolaunch.Repo.default_prefix()}\".auctions LIMIT 0",
           [],
           timeout: 1_000,
           log: false
         ) do
      {:ok, _result} -> true
      {:error, _error} -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
