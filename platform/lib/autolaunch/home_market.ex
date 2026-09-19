defmodule Autolaunch.HomeMarket do
  @moduledoc "Homepage-only public discovery and cursor scope."
  alias Autolaunch.{Auction, Token}
  alias Autolaunch.Robinhood.Auctions, as: RobinhoodAuctions
  alias AutolaunchWeb.PublicPage

  def options(params) do
    view = if params["view"] == "tokens", do: "tokens", else: "auctions"
    states = ~w(all created active failed)

    %{
      view: view,
      sort: choice(params["sort"], ~w(newest oldest), "newest"),
      display: choice(params["display"], ~w(grid table), "grid"),
      state: if(view == "tokens", do: "all", else: choice(params["state"], states, "all")),
      q: normalize_query(params["q"])
    }
  end

  def path(options, changes \\ %{}) do
    params =
      options
      |> Map.merge(changes)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> options()

    query =
      params |> Enum.reject(fn {_, value} -> value == "" end) |> Enum.sort() |> URI.encode_query()

    "/?" <> query
  end

  def read(options, cursor \\ nil) do
    scope = {:home_market, Map.drop(options, [:display])}
    resource = if options.view == "tokens", do: Token, else: Auction
    arguments = %{query: options.q, sort: options.sort}

    arguments =
      if resource == Auction,
        do: Map.merge(arguments, %{view: "new", state: options.state}),
        else: arguments

    with {:ok, page_options} <- PublicPage.options(cursor, scope, 24),
         {:ok, page} <-
           resource
           |> Ash.Query.for_read(:home_market, arguments)
           |> Ash.read(actor: nil, page: page_options) do
      {:ok,
       Map.merge(PublicPage.metadata(page, scope), %{
         records: page.results,
         kind: if(resource == Token, do: :token, else: :auction)
       })}
    end
  end

  @doc "The Robinhood auctions the same search, state filter and sort order show."
  def robinhood(%{view: "tokens"}), do: {:ok, []}

  def robinhood(options) do
    with {:ok, auctions} <- RobinhoodAuctions.list() do
      shown = Enum.filter(auctions, &(state?(&1, options.state) and matches?(&1, options.q)))
      {:ok, if(options.sort == "oldest", do: Enum.reverse(shown), else: shown)}
    end
  end

  # Home lists auctions that have not graduated; a graduated one is a token.
  defp state?(auction, "all"), do: auction.state != :graduated
  defp state?(auction, state), do: to_string(auction.state) == state

  defp matches?(_auction, ""), do: true

  defp matches?(auction, query) do
    query = String.downcase(query)

    Enum.any?(
      [auction.name, auction.symbol, auction.auction],
      &String.contains?(String.downcase(&1), query)
    )
  end

  defp choice(value, choices, fallback), do: if(value in choices, do: value, else: fallback)

  defp normalize_query(value) when is_binary(value),
    do: value |> String.trim() |> String.codepoints() |> Enum.take(80) |> Enum.join()

  defp normalize_query(_), do: ""
end
