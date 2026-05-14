defmodule AutolaunchWeb.Api.LaunchController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiError
  alias AutolaunchWeb.ApiErrorTranslator
  alias AutolaunchWeb.ClientIp

  import AutolaunchWeb.Api.ControllerHelpers

  def preview(conn, params) do
    case launch_module().preview_launch(params, current_actor(conn)) do
      {:ok, preview} ->
        json(conn, %{ok: true, preview: preview})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :launch_preview, reason)
    end
  end

  def create_job(conn, params) do
    actor = current_actor(conn)
    request_ip = ClientIp.from_conn(conn)

    case launch_module().create_launch_job(params, actor, request_ip) do
      {:ok, job} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, job_id: job.job_id, status: job.status, job: job})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :launch_create_job, reason)
    end
  end

  def show_job(conn, %{"id" => job_id}) do
    with {:ok, owner_addresses} <- actor_owner_addresses(current_actor(conn)),
         {:ok, response} <- launch_module().get_job_response(job_id),
         :ok <- authorize_job_owner(response, owner_addresses) do
      json(conn, Map.put(response, :ok, true))
    else
      {:error, :unauthorized} ->
        ApiError.render(
          conn,
          :unauthorized,
          "auth_required",
          "Signed agent or connected wallet required"
        )

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :launch_show_job, reason)
    end
  end

  defp launch_module do
    configured_module(:launch_controller, :launch_module, Launch)
  end

  defp actor_owner_addresses(nil), do: {:error, :unauthorized}

  defp actor_owner_addresses(current_actor) do
    addresses =
      [
        Map.get(current_actor, :wallet_address) || Map.get(current_actor, "wallet_address")
        | List.wrap(
            Map.get(current_actor, :wallet_addresses) ||
              Map.get(current_actor, "wallet_addresses")
          )
      ]
      |> Enum.map(&normalize_address/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if addresses == [], do: {:error, :unauthorized}, else: {:ok, addresses}
  end

  defp authorize_job_owner(%{job: %{owner_address: owner_address}}, owner_addresses) do
    if normalize_address(owner_address) in owner_addresses, do: :ok, else: {:error, :forbidden}
  end

  defp normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_address(_value), do: nil

  defp current_actor(conn),
    do: conn.assigns[:current_agent_claims] || conn.assigns[:current_human]
end
