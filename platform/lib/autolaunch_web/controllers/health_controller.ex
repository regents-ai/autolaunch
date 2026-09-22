defmodule AutolaunchWeb.HealthController do
  use AutolaunchWeb, :controller

  def show(conn, _params) do
    {status, body} =
      if database_ready?(), do: {:ok, "ok"}, else: {:service_unavailable, "unavailable"}

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
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
