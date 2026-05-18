defmodule Autolaunch.Swaps.UniswapClient do
  @moduledoc false

  @headers [
    {"content-type", "application/json"},
    {"x-universal-router-version", "2.0"},
    {"x-permit2-disabled", "true"}
  ]

  def check_approval(body, opts), do: post("/check_approval", body, opts)
  def quote(body, opts), do: post("/quote", body, opts)
  def swap(body, opts), do: post("/swap", body, opts)

  defp post(path, body, opts) do
    api_key = Keyword.get(opts, :api_key)
    base_url = opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")
    http_client = Keyword.get(opts, :http_client, Req)

    headers = [{"x-api-key", api_key} | @headers]

    case http_client.post(base_url <> path, json: body, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status, body: response}} when status in 200..299 and is_map(response) ->
        {:ok, response}

      {:ok, %{status: status, body: %{"errorCode" => code, "detail" => detail}}} ->
        {:error, {:uniswap_error, status, code, detail}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:uniswap_error, status, "request_failed", inspect(body)}}

      {:error, reason} ->
        {:error, {:uniswap_transport, reason}}
    end
  end
end
