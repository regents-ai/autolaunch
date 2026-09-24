defmodule Autolaunch.HomeMarket do
  @moduledoc "Public discovery and cursor scope for the home page and the auctions list."
  alias Autolaunch.{Auction, Token}
  alias AutolaunchWeb.PublicPage

  def options(params) do
    view = if params["view"] == "tokens", do: "tokens", else: "auctions"
    states = ~w(all created active ended failed graduated)

    %{
      view: view,
      sort:
        choice(
          params["sort"],
          if(view == "tokens", do: ~w(newest oldest), else: ~w(newest oldest ending volume)),
          "newest"
        ),
      display: choice(params["display"], ~w(grid table), "grid"),
      state: if(view == "tokens", do: "all", else: choice(params["state"], states, "all")),
      chain: choice(params["chain"], ~w(all base robinhood), "all"),
      kind: choice(params["kind"], ~w(all revstake memestake), "all"),
      x: params["x"] in [true, "true"],
      ens: params["ens"] in [true, "true"],
      github: params["github"] in [true, "true"],
      q: normalize_query(params["q"])
    }
  end

  def path(options, changes \\ %{}, base \\ "/") do
    params =
      options
      |> Map.merge(changes)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> options()

    defaults = options(%{})

    query =
      params
      |> Enum.reject(fn {key, value} -> value == "" or value == defaults[key] end)
      |> Enum.sort()
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  def read(options, cursor \\ nil) do
    scope = {:home_market, Map.drop(options, [:display])}
    resource = if options.view == "tokens", do: Token, else: Auction

    arguments = %{
      query: options.q,
      sort: options.sort,
      chain: options.chain,
      kind: options.kind,
      x: options.x,
      ens: options.ens,
      github: options.github
    }

    query =
      if resource == Auction,
        do:
          Auction
          |> Ash.Query.for_read(
            :home_market,
            Map.merge(arguments, %{view: "new", state: options.state}),
            actor: nil
          )
          |> Ash.Query.load(:fdv),
        else: Ash.Query.for_read(Token, :home_market, arguments, actor: nil)

    with {:ok, page_options} <- PublicPage.options(cursor, scope, 24),
         {:ok, page} <- Ash.read(query, page: page_options) do
      {:ok,
       Map.merge(PublicPage.metadata(page, scope), %{
         records: page.results,
         kind: if(resource == Token, do: :token, else: :auction)
       })}
    end
  end

  @doc """
  The first `count` records again, a page at a time, so a live reread keeps
  every page the reader has loaded. At least one page is read.
  """
  def reread(options, count), do: reread(options, count, nil, [])

  defp reread(options, count, cursor, records) do
    with {:ok, page} <- read(options, cursor) do
      records = records ++ page.records

      if page.has_more and length(records) < count,
        do: reread(options, count, page.next_cursor, records),
        else: {:ok, %{page | records: records}}
    end
  end

  defp choice(value, choices, fallback), do: if(value in choices, do: value, else: fallback)

  defp normalize_query(value) when is_binary(value),
    do: value |> String.trim() |> String.codepoints() |> Enum.take(80) |> Enum.join()

  defp normalize_query(_), do: ""
end
