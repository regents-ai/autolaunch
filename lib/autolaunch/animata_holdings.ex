defmodule Autolaunch.AnimataHoldings do
  @moduledoc false

  alias Autolaunch.Evm

  @collections ["animata", "regent-animata-ii", "regents-club"]
  @page_limit 100

  @callback get(URI.t() | String.t(), keyword()) ::
              {:ok, %{status: integer(), body: map()}} | {:error, term()}

  @spec holder?(String.t() | nil) :: boolean()
  def holder?(wallet_address) do
    with wallet when is_binary(wallet) <- Evm.normalize_address(wallet_address),
         api_key when is_binary(api_key) and api_key != "" <- opensea_api_key(),
         true <- Enum.any?(@collections, &collection_holder?(wallet, &1, api_key)) do
      true
    else
      _other -> false
    end
  end

  defp collection_holder?(wallet, collection, api_key) do
    url =
      URI.new!("https://api.opensea.io/api/v2/chain/base/account/#{wallet}/nfts")
      |> URI.append_query("collection=#{collection}&limit=#{@page_limit}")

    case http_client().get(url, headers: [{"accept", "application/json"}, {"x-api-key", api_key}]) do
      {:ok, %{status: status, body: %{"nfts" => [_first | _rest]}}} when status in 200..299 ->
        true

      _other ->
        false
    end
  end

  defp opensea_api_key do
    :autolaunch
    |> Application.get_env(:animata_holdings, [])
    |> Keyword.get(:opensea_api_key)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> System.get_env("OPENSEA_API_KEY")
    end
  end

  defp http_client do
    :autolaunch
    |> Application.get_env(:animata_holdings, [])
    |> Keyword.get(:http_client, __MODULE__.HttpClient)
  end

  defmodule HttpClient do
    @moduledoc false
    @behaviour Autolaunch.AnimataHoldings

    @impl true
    def get(url, options) do
      case Req.get(url, options) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
