defmodule AutolaunchWeb.Api.LaunchController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiError

  def preview(conn, params) do
    case Launch.preview_launch(params, conn.assigns[:current_human]) do
      {:ok, preview} ->
        json(conn, %{ok: true, preview: preview})

      {:error, {:agent_not_eligible, agent}} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "agent_not_eligible",
          "Agent is not eligible for launch",
          %{agent: agent}
        )

      {:error, :agent_not_found} ->
        ApiError.render(conn, :not_found, "agent_not_found", "Agent not found")

      {:error, :unauthorized} ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "launch_preview_invalid", inspect(reason))
    end
  end

  def create_job(conn, params) do
    current_human = conn.assigns[:current_human]
    request_ip = client_ip(conn)

    case Launch.create_launch_job(params, current_human, request_ip) do
      {:ok, job} ->
        json(conn, %{ok: true, job_id: job.job_id, status: job.status, job: job})

      {:error, {:agent_not_eligible, agent}} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "agent_not_eligible",
          "Agent is not eligible for launch",
          %{agent: agent}
        )

      {:error, :wallet_mismatch} ->
        ApiError.render(
          conn,
          :forbidden,
          "wallet_mismatch",
          "Connected wallet does not match current Privy session"
        )

      {:error, :invalid_chain_id} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_chain_id",
          "Chain ID must be Ethereum Sepolia (11155111)"
        )

      {:error, :invalid_wallet_address} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_wallet",
          "Wallet address is invalid"
        )

      {:error, :message_required} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "signature_message_required",
          "SIWA message is required"
        )

      {:error, :signature_required} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "signature_required",
          "Wallet signature is required"
        )

      {:error, :nonce_required} ->
        ApiError.render(conn, :unprocessable_entity, "nonce_required", "SIWA nonce is required")

      {:error, :unauthorized} ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      {:error, {:sidecar_error, status, body}} ->
        conn |> put_status(status) |> json(body)

      {:error, {:verify_failed, response}} ->
        conn |> put_status(:unauthorized) |> json(response)

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "launch_invalid", inspect(reason))
    end
  end

  def show_job(conn, %{"id" => job_id} = params) do
    owner_address = Map.get(params, "address")

    case Launch.get_job_response(job_id, owner_address) do
      nil ->
        ApiError.render(conn, :not_found, "job_not_found", "Launch job not found")

      {:error, :forbidden} ->
        ApiError.render(
          conn,
          :forbidden,
          "job_forbidden",
          "Launch job does not belong to this owner"
        )

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
end
