defmodule AutolaunchWeb.SearchLive do
  @moduledoc """
  The search window every page opens from the header's search button, ⌘K
  (Ctrl K) or "/": the chain, type and kind to look in, then the recently
  popular list (`Autolaunch.Popular`) until something is typed, and the
  auctions and tokens that match it (`Autolaunch.HomeMarket`) once it is.
  Nothing is read until the window first opens. Enter or a click opens a
  result's page; "See all results" opens the home list for the same search.

  The `SiteSearch` hook opens and closes the window and moves the highlighted
  row; this view only reads and renders.
  """
  use Phoenix.LiveView, layout: false

  import AutolaunchWeb.Components.ChainIcon

  alias Autolaunch.{HomeMarket, Popular, Token}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.Paths
  alias Phoenix.LiveView.{AsyncResult, JS}

  @choices %{
    chain: [{"all", "All"}, {"base", "Base"}, {"robinhood", "Robinhood"}],
    kind: [{"all", "All"}, {"revstake", "Revstake"}, {"memestake", "Memestake"}],
    show: [{"all", "All"}, {"auctions", "Auctions"}, {"tokens", "Tokens"}]
  }

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       query: "",
       filters: %{chain: "all", kind: "all", show: "all"},
       rates: AsyncResult.loading(),
       popular: nil,
       searched: nil,
       results: nil
     )}
  end

  # The popular list and the dollar prices it is ranked with are read the
  # first time the window opens on this page, and again on the next opening
  # when that read failed.
  def handle_event("open", _params, %{assigns: %{popular: popular}} = socket) do
    if is_nil(popular) or failed?(popular),
      do: {:noreply, read_popular(socket)},
      else: {:noreply, socket}
  end

  def handle_event("type", %{"q" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> search()}

  def handle_event("filter", %{"name" => name, "choice" => choice}, socket) do
    case Enum.find(@choices, fn {key, choices} ->
           Atom.to_string(key) == name and List.keymember?(choices, choice, 0)
         end) do
      {key, _choices} ->
        {:noreply, socket |> update(:filters, &Map.put(&1, key, choice)) |> search()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_async(:popular, {:ok, {rates, {:ok, entries}}}, socket),
    do: {:noreply, assign(socket, rates: rates, popular: AsyncResult.ok(entries))}

  def handle_async(:popular, {:ok, {rates, failure}}, socket),
    do:
      {:noreply,
       assign(socket,
         rates: rates,
         popular: AsyncResult.failed(socket.assigns.popular, failure)
       )}

  def handle_async(:popular, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       rates: AsyncResult.failed(socket.assigns.rates, {:exit, reason}),
       popular: AsyncResult.failed(socket.assigns.popular, {:exit, reason})
     )}
  end

  # Only the answer to the latest search is shown; an earlier one that
  # arrives late is dropped.
  def handle_async(
        :results,
        {:ok, {searched, result}},
        %{assigns: %{searched: searched}} = socket
      ) do
    results =
      case result do
        {:ok, found} -> AsyncResult.ok(found)
        failure -> AsyncResult.failed(%AsyncResult{}, failure)
      end

    {:noreply, assign(socket, :results, results)}
  end

  def handle_async(:results, {:ok, _earlier}, socket), do: {:noreply, socket}

  def handle_async(:results, {:exit, reason}, socket),
    do: {:noreply, assign(socket, :results, AsyncResult.failed(%AsyncResult{}, {:exit, reason}))}

  defp read_popular(socket) do
    socket
    |> assign(:popular, AsyncResult.loading())
    |> start_async(:popular, fn ->
      rates = AsyncResult.ok(MarketCard.figure_rates())
      {rates, Popular.read(&MarketCard.figure_rate(rates, &1))}
    end)
  end

  # What is shown while a new search reads stays until its answer replaces it.
  defp search(socket) do
    query = Autolaunch.Search.normalize(socket.assigns.query)
    filters = socket.assigns.filters
    searched = {query, filters}

    cond do
      query == "" ->
        assign(socket, searched: nil, results: nil)

      searched == socket.assigns.searched ->
        socket

      true ->
        socket
        |> assign(
          searched: searched,
          results: AsyncResult.loading(socket.assigns.results || %AsyncResult{})
        )
        |> start_async(:results, fn -> {searched, read_results(query, filters)} end)
    end
  end

  defp read_results(query, filters) do
    limit = if filters.show == "all", do: 5, else: 8

    with {:ok, auctions} <- records("auctions", query, filters, limit),
         {:ok, tokens} <- records("tokens", query, filters, limit) do
      {:ok, %{auctions: auctions, tokens: tokens}}
    end
  end

  defp records(view, _query, %{show: show}, _limit) when show not in ["all", view], do: {:ok, []}

  defp records(view, query, filters, limit) do
    options =
      HomeMarket.options(%{
        "view" => view,
        "q" => query,
        "chain" => filters.chain,
        "kind" => filters.kind
      })

    with {:ok, page} <- HomeMarket.read(options, nil, limit), do: {:ok, page.records}
  end

  # The home list for the same search. It shows auctions or tokens, so a
  # search of both opens its auctions.
  defp all_results_path(query, filters) do
    HomeMarket.path(HomeMarket.options(%{}), %{
      q: query,
      view: if(filters.show == "tokens", do: "tokens", else: "auctions"),
      chain: filters.chain,
      kind: filters.kind
    })
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        normalized: Autolaunch.Search.normalize(assigns.query),
        choices: @choices
      )

    ~H"""
    <div :if={!Autolaunch.Prelaunch.read_only?()} id="site-search-window" phx-hook="SiteSearch">
      <dialog
        id="site-search-dialog"
        class="site-search"
        aria-label="Search auctions and tokens"
        {AutolaunchWeb.Motion.panel("dialog", ["open"])}
      >
        <form id="site-search-form" class="site-search__field" role="search" phx-change="type">
          <svg
            viewBox="0 0 24 24"
            width="22"
            height="22"
            fill="none"
            stroke="currentColor"
            stroke-width="1.5"
            aria-hidden="true"
          ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
          <input
            id="site-search-input"
            type="search"
            name="q"
            value={@query}
            role="combobox"
            aria-label="Search auctions and tokens"
            aria-expanded="true"
            aria-controls="site-search-list"
            aria-autocomplete="list"
            placeholder="Search auctions and tokens"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            enterkeyhint="go"
            autofocus
            phx-debounce="150"
            phx-mounted={JS.ignore_attributes(["aria-activedescendant"])}
          />
          <button type="button" class="site-search__close" aria-label="Close search" data-search-close>
            <kbd class="site-search__esc">Esc</kbd><span class="site-search__close-word">Close</span>
          </button>
        </form>

        <div class="site-search__filters">
          <.choices name="chain" label="Chain" choices={@choices.chain} chosen={@filters.chain} />
          <.choices name="kind" label="Type" choices={@choices.kind} chosen={@filters.kind} />
          <.choices name="show" label="Show" choices={@choices.show} chosen={@filters.show} />
        </div>

        <div class="site-search__body">
          <div
            id="site-search-list"
            class="site-search__list"
            role="listbox"
            aria-label={if @normalized == "", do: "Recently popular", else: "Results"}
            aria-busy={to_string(busy?(@normalized, @popular, @results))}
          >
            <.popular
              :if={@normalized == ""}
              popular={@popular}
              filters={@filters}
            />
            <.results
              :if={@normalized != "" and match?(%AsyncResult{result: %{}}, @results)}
              results={@results.result}
              rates={@rates}
              path={all_results_path(@normalized, @filters)}
            />
          </div>
          <.notice
            normalized={@normalized}
            popular={@popular}
            results={@results}
            filters={@filters}
          />
        </div>

        <p class="site-search__keys" aria-hidden="true">
          <span><kbd>↑</kbd><kbd>↓</kbd> navigate</span>
          <span><kbd>Enter</kbd> open</span>
          <span><kbd>Esc</kbd> close</span>
        </p>
      </dialog>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :choices, :list, required: true
  attr :chosen, :string, required: true

  # One row of choices: the chosen one is pressed.
  defp choices(assigns) do
    ~H"""
    <div class="site-search__choices" role="group" aria-label={@label}>
      <span class="site-search__choices-label" aria-hidden="true">{@label}</span>
      <button
        :for={{value, text} <- @choices}
        type="button"
        class="site-search__choice"
        phx-click="filter"
        phx-value-name={@name}
        phx-value-choice={value}
        aria-pressed={to_string(@chosen == value)}
      >
        <.chain_icon :if={@name == "chain" and value != "all"} chain={String.to_existing_atom(value)} />
        {text}
      </button>
    </div>
    """
  end

  attr :popular, :any, required: true
  attr :filters, :map, required: true

  defp popular(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        case assigns.popular do
          %AsyncResult{ok?: true, result: entries} -> Popular.pick(entries, assigns.filters, 8)
          _pending -> []
        end
      )

    ~H"""
    <div :if={@entries != []} role="group" aria-labelledby="site-search-popular-title">
      <p id="site-search-popular-title" class="site-search__heading">
        Recently popular <span>Last 24 hours</span>
      </p>
      <.row
        :for={entry <- @entries}
        id={"site-search-popular-#{entry.kind}-#{entry.record.id}"}
        kind={entry.kind}
        record={entry.record}
      >
        <strong>${MarketCard.compact(entry.usd)}</strong>
        <small>{if entry.kind == :auction, do: "bid today", else: "traded today"}</small>
      </.row>
    </div>
    """
  end

  attr :results, :map, required: true
  attr :rates, :any, required: true
  attr :path, :string, required: true

  defp results(assigns) do
    ~H"""
    <div :if={@results.auctions != []} role="group" aria-labelledby="site-search-auctions-title">
      <p id="site-search-auctions-title" class="site-search__heading">Auctions</p>
      <.row
        :for={auction <- @results.auctions}
        id={"site-search-auction-#{auction.id}"}
        kind={:auction}
        record={auction}
      >
        <strong>{MarketCard.bid_volume(auction)}</strong>
        <small>total bid</small>
      </.row>
    </div>
    <div :if={@results.tokens != []} role="group" aria-labelledby="site-search-tokens-title">
      <p id="site-search-tokens-title" class="site-search__heading">Tokens</p>
      <.row
        :for={token <- @results.tokens}
        id={"site-search-token-#{token.id}"}
        kind={:token}
        record={token}
      >
        <strong><MarketCard.token_price
          token={token}
          rate={MarketCard.figure_rate(@rates, token.auction)}
        /></strong>
        <small>token price</small>
      </.row>
    </div>
    <.link
      :if={@results.auctions != [] or @results.tokens != []}
      id="site-search-all"
      navigate={@path}
      role="option"
      aria-selected="false"
      class="site-search__all"
    >
      See all results
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true, values: [:auction, :token]
  attr :record, :map, required: true
  slot :inner_block, required: true, doc: "the row's figure and what it measures"

  # A result: an auction's picture is square with a gavel on its corner, a
  # token's is round like a coin; the chain's mark sits on the other corner.
  defp row(assigns) do
    assigns = assign(assigns, :face, face(assigns.kind, assigns.record))

    ~H"""
    <.link
      navigate={@face.path}
      id={@id}
      role="option"
      aria-selected="false"
      class="site-search__row"
    >
      <span class={["site-search__art", "site-search__art--#{@kind}"]}>
        <img
          :if={@face.image}
          src={@face.image}
          alt=""
          width="44"
          height="44"
          loading="lazy"
          decoding="async"
        />
        <span :if={!@face.image} class="site-search__initial" aria-hidden="true">
          {String.first(@face.name || "?")}
        </span>
        <span :if={@kind == :auction} class="site-search__gavel" aria-hidden="true">
          <svg viewBox="0 0 16 16" fill="currentColor">
            <g transform="rotate(-45 8 7)">
              <rect x="3.5" y="2" width="9" height="4.5" rx="1.25" /><rect
                x="7.1"
                y="6"
                width="1.8"
                height="8.5"
                rx=".9"
              />
            </g>
          </svg>
        </span>
        <.chain_icon chain={@face.chain} class="site-search__chain" />
      </span>
      <span class="site-search__name">
        <strong>{@face.name}</strong>
        <small>
          <span class="visually-hidden">{if @kind == :auction, do: "Auction", else: "Token"},</span>
          {Enum.join(@face.facts, " · ")}
        </small>
      </span>
      <span class="site-search__figure">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  defp face(:auction, auction) do
    %{
      name: auction.title,
      image: present(auction.image),
      path: Paths.auction(auction),
      chain: chain(auction),
      facts: [auction.token_symbol, type(auction), MarketCard.state_label(auction.state)]
    }
  end

  defp face(:token, token) do
    presentation = Token.presentation(token)

    %{
      name: presentation.name,
      image: present(presentation.image),
      path: Paths.token(token.auction),
      chain: chain(token.auction),
      facts: [presentation.symbol, type(token.auction)]
    }
  end

  defp chain(auction), do: if(RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base)

  defp type(%{kind: :agent}), do: "Revstake"
  defp type(_auction), do: "Memestake"

  defp present(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp present(_value), do: nil

  attr :normalized, :string, required: true
  attr :popular, :any, required: true
  attr :results, :any, required: true
  attr :filters, :map, required: true

  # What the list says when it has no rows to show: still reading, nothing
  # found, or unable to read.
  defp notice(%{normalized: ""} = assigns) do
    ~H"""
    <p :if={!ready?(@popular)} class="site-search__notice" role="status">
      {if failed?(@popular),
        do: "The popular list could not be read just now. Try again in a moment.",
        else: "Loading what is popular…"}
    </p>
    <p
      :if={ready?(@popular) and Popular.pick(@popular.result, @filters, 1) == []}
      class="site-search__notice"
      role="status"
    >
      {if @filters == %{chain: "all", kind: "all", show: "all"},
        do: "Nothing has been bid on or traded in the last 24 hours.",
        else: "Nothing matching these choices has been bid on or traded in the last 24 hours."}
    </p>
    """
  end

  defp notice(assigns) do
    ~H"""
    <p :if={loading?(@results) and is_nil(@results.result)} class="site-search__notice" role="status">
      Searching…
    </p>
    <p :if={failed?(@results)} class="site-search__notice" role="status">
      Search is unavailable just now. Try again in a moment.
    </p>
    <div
      :if={match?(%AsyncResult{result: %{auctions: [], tokens: []}}, @results)}
      class="site-search__notice"
      role="status"
    >
      <p>No {nothing_found(@filters.show)} match “{@normalized}”.</p>
      <p>Try a different name, ticker, address or creator.</p>
    </div>
    """
  end

  defp nothing_found("auctions"), do: "auctions"
  defp nothing_found("tokens"), do: "tokens"
  defp nothing_found("all"), do: "auctions or tokens"

  defp busy?("", popular, _results), do: loading?(popular)
  defp busy?(_query, _popular, results), do: loading?(results)

  defp ready?(async), do: match?(%AsyncResult{ok?: true}, async)

  defp loading?(async),
    do: match?(%AsyncResult{loading: loading} when loading not in [nil, false], async)

  defp failed?(async),
    do: match?(%AsyncResult{failed: failed} when failed not in [nil, false], async)
end
