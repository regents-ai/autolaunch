defmodule Autolaunch.Stocks.UpcomingCatalog do
  @moduledoc """
  The stocks page's established Available to Pair list and dated research for
  its two preview sections. Research never admits a stock or configures a route.
  Section membership comes from the catalog: an empty local admission cache
  cannot remove an established stock or move it into the preview.
  """

  @source Application.app_dir(:autolaunch, "priv/stocks/upcoming-2026-10-14.json")
  @external_resource @source
  @stocks @source |> File.read!() |> Jason.decode!() |> Map.fetch!("stocks")
  @chains [base: "Base", robinhood: "Robinhood"]

  @doc "The catalog's identities and dated observations."
  def stocks, do: @stocks

  @doc "The established stock list and the two preview groups, without changing admission."
  def chains do
    Enum.map(@chains, fn {chain, name} ->
      grouped =
        @stocks
        |> Enum.filter(&(&1["chain"] == Atom.to_string(chain)))
        |> Enum.map(&status/1)
        |> Enum.group_by(& &1["section"])

      %{
        chain: chain,
        name: name,
        available: sorted(grouped, "available"),
        eligible: sorted(grouped, "soon"),
        feed_required: sorted(grouped, "feed_required")
      }
    end)
  end

  defp status(%{"section" => "available"} = stock), do: Map.put(stock, "status", nil)

  defp status(%{"section" => "soon"} = stock),
    do: Map.put(stock, "status", "Not open for launches yet")

  defp status(%{"section" => "feed_required"} = stock),
    do: Map.put(stock, "status", "Chainlink feed required; other checks may also be pending")

  defp sorted(grouped, "available"),
    do: grouped |> Map.get("available", []) |> Enum.sort_by(& &1["symbol"])

  defp sorted(grouped, section) do
    grouped
    |> Map.get(section, [])
    |> Enum.sort_by(&{&1["rank"] || 1_000, &1["ticker"], &1["id"]})
  end
end
