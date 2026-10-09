defmodule Autolaunch.DexScreener do
  @moduledoc """
  Whether DexScreener lists the exact public pool. Answers, including unavailable
  ones, expire after one minute; the API is the source of truth for its listing.
  """

  @cache :autolaunch_dex_screener
  @api "https://api.dexscreener.com/latest/dex/pairs"

  def cache, do: @cache

  def listed?(network, pool_id) when network in ["base", "robinhood"] and is_binary(pool_id) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, pool_id) do
      cached(network, String.downcase(pool_id))
    else
      false
    end
  end

  def listed?(_network, _pool_id), do: false

  defp cached(network, pool_id) do
    key = "autolaunch:dexscreener:v1:#{network}:#{pool_id}"

    case Cachex.fetch(@cache, key, fn -> {:commit, read(network, pool_id)} end) do
      {status, listed?} when status in [:ok, :commit] and is_boolean(listed?) -> listed?
      _unavailable -> false
    end
  end

  defp read(network, pool_id) do
    client = Application.get_env(:autolaunch, :autolaunch_market_http_client, Req)

    case client.get("#{@api}/#{network}/#{pool_id}",
           connect_options: [timeout: 1_500],
           receive_timeout: 2_000,
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: 200, body: %{"pairs" => pairs}}} when is_list(pairs) ->
        Enum.any?(pairs, fn
          %{"chainId" => ^network, "pairAddress" => address} when is_binary(address) ->
            String.downcase(address) == pool_id

          _other ->
            false
        end)

      _unavailable ->
        false
    end
  end
end
