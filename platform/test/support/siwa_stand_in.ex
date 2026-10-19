defmodule Autolaunch.SiwaStandIn do
  @moduledoc """
  A local stand-in for the sign-in service's agent activity
  (`POST /api/shared/siwa/activity`), for a lab server started with
  `AUTOLAUNCH_SIWA_STAND_IN=1` (config/test.exs), so the side panel's agents
  show where each was last active without the real service or its reader key.

  An agent whose wallet ends in `0` has not been active since it paired; any
  other was last active on Autolaunch five minutes ago and on Patchbay the day
  before. It verifies no signed request: anything else is not found.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: "/api/shared/siwa/activity"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    %{"wallet_address" => wallet} = Jason.decode!(body)
    answer(conn, 200, %{"data" => %{"days" => days(wallet), "agentRegistration" => nil}})
  end

  def call(conn, _opts), do: answer(conn, 404, %{"error" => %{"code" => "not_found"}})

  defp days(wallet) do
    if String.ends_with?(wallet, "0") do
      []
    else
      now = DateTime.utc_now()
      recent = DateTime.add(now, -5, :minute)
      yesterday = DateTime.add(now, -1, :day)

      [day("autolaunch", recent), day("patchbay", yesterday)]
    end
  end

  defp day(audience, at),
    do: %{
      "audience" => audience,
      "day" => at |> DateTime.to_date() |> Date.to_iso8601(),
      "first_seen_at" => at |> DateTime.add(-1, :hour) |> DateTime.to_iso8601(),
      "last_seen_at" => DateTime.to_iso8601(at)
    }

  defp answer(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
end
