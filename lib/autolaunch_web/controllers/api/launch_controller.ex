defmodule AutolaunchWeb.Api.LaunchController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiErrorTranslator

  def preview(conn, params) do
    case launch_module().preview_launch(params, conn.assigns[:current_human]) do
      {:ok, preview} ->
        json(conn, %{ok: true, preview: preview})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :launch_preview, reason)
    end
  end

  def create_job(conn, params) do
    current_human = conn.assigns[:current_human]
    request_ip = client_ip(conn)

    case launch_module().create_launch_job(params, current_human, request_ip) do
      {:ok, job} ->
        json(conn, %{ok: true, job_id: job.job_id, status: job.status, job: job})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :launch_create_job, reason)
    end
  end

  def show_job(conn, %{"id" => job_id} = params) do
    owner_address = Map.get(params, "address")

    case launch_module().get_job_response(job_id, owner_address) do
      nil ->
        ApiErrorTranslator.render(conn, :launch_show_job, :job_not_found)

      {:error, :forbidden} ->
        ApiErrorTranslator.render(conn, :launch_show_job, :forbidden)

      response ->
        json(conn, Map.put(response, :ok, true))
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",", parts: 2) |> hd() |> String.trim()
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:launch_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
