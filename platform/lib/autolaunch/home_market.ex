defmodule Autolaunch.HomeMarket do
  @moduledoc "Public discovery and cursor scope for the website's lists and the public JSON API."
  alias Autolaunch.{Auction, Token}
  alias AutolaunchWeb.PublicPage

  def options(params) do
    view = if params["view"] == "tokens", do: "tokens", else: "auctions"
    states = ~w(all created active ended failed graduated finished)

    %{
      view: view,
      sort:
        if(view == "tokens",
          do: "newest",
          else: choice(params["sort"], ~w(newest ending volume), "newest")
        ),
      display: choice(params["display"], ~w(list grid), "list"),
      state: if(view == "tokens", do: "all", else: choice(params["state"], states, "all")),
      chain: choice(params["chain"], ~w(all base robinhood), "all"),
      kind: choice(params["kind"], ~w(all revstake memestock), "all"),
      x: params["x"] in [true, "true"],
      ens: params["ens"] in [true, "true"],
      github: params["github"] in [true, "true"],
      q: Autolaunch.Search.normalize(params["q"])
    }
  end

  def path(options, changes \\ %{}, base \\ "/") do
    params =
      options
      |> Map.merge(changes)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> options()

    # /auctions and /tokens name their view in the route itself.
    defaults = if base == "/", do: options(%{}), else: options(%{"view" => params.view})

    query =
      params
      |> Enum.reject(fn {key, value} -> value == "" or value == defaults[key] end)
      |> Enum.sort()
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  # The site's own bookkeeping on an auction: when it last wrote the record and
  # where its next read of the auction's chain starts, rewritten after every read.
  # The JSON API reports `updated_at`; the pages show none of them, and leaving
  # them out means a page's records change, and the page is sent anything, only
  # when something it shows has moved.
  @unshown [:updated_at, :activity_next_block, :activity_last_hash]

  @doc "A page of a list as the website shows it."
  def read(options, cursor \\ nil, limit \\ 24), do: page(options, cursor, limit, @unshown)

  @doc "A page of a list with each auction's whole record, for the JSON API."
  def read_records(options, cursor, limit), do: page(options, cursor, limit, [])

  defp page(options, cursor, limit, unshown) do
    scope = {:home_market, Map.drop(options, [:display])}
    resource = if options.view == "tokens", do: Token, else: Auction

    arguments = %{
      query: options.q,
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
            Map.merge(arguments, %{view: "new", state: options.state, sort: options.sort}),
            actor: nil
          )
          |> Ash.Query.load(:fdv)
          |> Ash.Query.deselect(unshown),
        else:
          Token
          |> Ash.Query.for_read(:home_market, arguments, actor: nil)
          |> Ash.Query.load(:market_cap)

    with {:ok, page_options} <- PublicPage.options(cursor, scope, limit),
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
end
