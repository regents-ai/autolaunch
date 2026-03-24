defmodule AutolaunchWeb.AgentSiwaController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Siwa
  alias AutolaunchWeb.ApiError

  def nonce(conn, params) do
    with {:ok, chain_id} <- normalize_chain_id(Map.get(params, "chainId")),
         {:ok, response} <-
           Siwa.issue_nonce(%{
             wallet_address: Map.get(params, "walletAddress", Map.get(params, "address")),
             chain_id: chain_id,
             audience: Map.get(params, "audience", "autolaunch")
           }) do
      json(conn, response)
    else
      {:error, :invalid_chain_id} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_chain_id",
          "Chain ID must be Ethereum mainnet (1)"
        )

      {:error, {:sidecar_error, status, body}} ->
        conn |> put_status(status) |> json(body)

      {:error, reason} ->
        ApiError.render(conn, :bad_gateway, "siwa_unavailable", inspect(reason))
    end
  end

  def verify(conn, params) do
    with {:ok, chain_id} <- normalize_chain_id(Map.get(params, "chainId")),
         {:ok, response} <-
           Siwa.verify_wallet_signature(%{
             wallet_address: Map.get(params, "walletAddress", Map.get(params, "address")),
             chain_id: chain_id,
             nonce: Map.get(params, "nonce"),
             message: Map.get(params, "message"),
             signature: Map.get(params, "signature"),
             registry_address:
               Map.get(params, "registryAddress", Map.get(params, "registry_address")),
             token_id: Map.get(params, "tokenId", Map.get(params, "token_id"))
           }) do
      json(conn, response)
    else
      {:error, :invalid_chain_id} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_chain_id",
          "Chain ID must be Ethereum mainnet (1)"
        )

      {:error, {:verify_failed, response}} ->
        conn |> put_status(:unauthorized) |> json(response)

      {:error, {:sidecar_error, status, body}} ->
        conn |> put_status(status) |> json(body)

      {:error, reason} ->
        ApiError.render(conn, :bad_gateway, "siwa_unavailable", inspect(reason))
    end
  end

  defp normalize_chain_id(value) when is_integer(value) do
    if value == 1, do: {:ok, value}, else: {:error, :invalid_chain_id}
  end

  defp normalize_chain_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_chain_id(parsed)
      _ -> {:error, :invalid_chain_id}
    end
  end

  defp normalize_chain_id(_value), do: {:error, :invalid_chain_id}
end
