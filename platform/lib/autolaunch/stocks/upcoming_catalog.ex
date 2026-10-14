defmodule Autolaunch.Stocks.UpcomingCatalog do
  @moduledoc """
  Dated research for the public stocks page. Pool observations and unresolved
  identities are kept as supplied; they never admit a stock or configure a route.
  Available stocks come from `Assets`, joined by chain and token address, so a
  ticker shared by two issuers cannot inherit another token's admission.
  """

  alias Autolaunch.Stocks.{Companies, PriceFeeds}

  @source Application.app_dir(:autolaunch, "priv/stocks/upcoming-2026-10-14.json")
  @external_resource @source
  @stocks @source |> File.read!() |> Jason.decode!() |> Map.fetch!("stocks")
  @chains [base: "Base", robinhood: "Robinhood"]

  @doc "The research observations, without any claim of current admission."
  def stocks, do: @stocks

  @doc "Groups research and saved admitted stocks for each chain, without writing either."
  def chains(admitted) do
    Enum.map(@chains, fn {chain, name} ->
      saved = Map.get(admitted, chain, [])
      by_address = Map.new(saved, &{String.downcase(&1.address), &1})
      research = Enum.filter(@stocks, &(&1["chain"] == Atom.to_string(chain)))
      researched = MapSet.new(research, &String.downcase(&1["token_address"] || ""))

      catalog = Enum.map(research, &research_record(&1, by_address))

      additions =
        saved
        |> Enum.reject(&MapSet.member?(researched, String.downcase(&1.address)))
        |> Enum.map(&new_stock(&1, chain))

      grouped = Enum.group_by(catalog ++ additions, & &1["section"])

      %{
        chain: chain,
        name: name,
        available: sorted(grouped, "available"),
        eligible: sorted(grouped, "soon"),
        feed_required: sorted(grouped, "feed_required")
      }
    end)
  end

  defp research_record(stock, by_address) do
    case Map.get(by_address, String.downcase(stock["token_address"] || "")) do
      nil -> pending(stock)
      saved -> admitted(stock, saved)
    end
  end

  defp pending(%{"section" => "available"} = stock) do
    Map.merge(stock, %{
      "section" => "soon",
      "status" => "Previously listed; current admission is not confirmed"
    })
  end

  defp pending(%{"section" => "soon"} = stock),
    do: Map.put(stock, "status", "Pending admission or verification")

  defp pending(%{"section" => "feed_required"} = stock),
    do: Map.put(stock, "status", "Chainlink feed required; other checks may also be pending")

  defp admitted(stock, saved) do
    Map.merge(stock, %{
      "section" => "available",
      "symbol" => saved.symbol,
      "token_address" => saved.address,
      "feed_address" => saved.feed,
      "feed_status" => "Launchpad's saved feed; current price round is not checked here",
      "status" => "Admitted by the launchpad",
      "blocker" => nil
    })
  end

  defp new_stock(saved, chain) do
    ticker = PriceFeeds.ticker(saved.symbol)

    %{
      "id" => "#{chain}-#{String.downcase(saved.address)}",
      "section" => "available",
      "symbol" => saved.symbol,
      "name" => saved.name,
      "ticker" => ticker,
      "token_address" => saved.address,
      "feed_address" => saved.feed,
      "feed_status" => "Launchpad's saved feed; current price round is not checked here",
      "company_url" => Companies.website(ticker),
      "view_url" => nil,
      "status" => "Admitted by the launchpad",
      "blocker" => nil,
      "rank" => nil,
      "pools" => []
    }
  end

  defp sorted(grouped, section) do
    grouped
    |> Map.get(section, [])
    |> Enum.sort_by(&{&1["rank"] || 1_000, &1["ticker"], &1["id"]})
  end
end
