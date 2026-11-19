defmodule AutolaunchWeb.StockMarkdown do
  @moduledoc "The Markdown view of the public, database-free stock detail catalog."

  alias Autolaunch.Stocks.Assets
  alias AutolaunchWeb.UsdValue

  def render(stock, chain) do
    details = [
      "# #{stock["symbol"]} · #{stock["name"]}",
      "",
      "- Network: #{chain.name}",
      "- Token issuer: #{Assets.issuer(chain.chain)}",
      "- Token address: #{address(stock["token_address"])}",
      "- Chainlink feed address: #{address(stock["feed_address"])}",
      "- Status: #{stock["status"] || "Available to Pair in the published catalog"}"
    ]

    pools = Enum.with_index(stock["pools"], 1)

    Enum.join(details ++ Enum.flat_map(pools, &pool/1) ++ no_pools(pools), "\n") <> "\n"
  end

  defp pool({pool, index}) do
    id = if pool["kind"] == "v4", do: "Pool ID", else: "Pool address"

    [
      "",
      "## Pool #{index}",
      "- Venue: #{pool["venue"] || "Unknown"}",
      "- #{id}: #{address(pool["identifier"])}",
      "- Observed liquidity: #{liquidity(pool["liquidity_usd"])}",
      "- Observed: #{pool["observed_at"] || "Date not available"}#{historical(pool)}"
    ] ++ if(pool["manager"], do: ["- PoolManager address: #{address(pool["manager"])}"], else: [])
  end

  defp historical(%{"historical" => true}), do: " · Historical; current depth unknown"
  defp historical(_pool), do: ""

  defp address(nil), do: "Not verified"
  defp address(value), do: "`#{value}`"

  defp liquidity(nil), do: "Unknown"
  defp liquidity(usd), do: usd |> Decimal.new() |> UsdValue.dollars()

  defp no_pools([]), do: ["", "Pool address and liquidity not available."]
  defp no_pools(_pools), do: []
end
