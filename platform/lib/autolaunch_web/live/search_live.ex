defmodule AutolaunchWeb.SearchLive do
  @moduledoc """
  The search window every page shares. Pressing the header's search bar or
  ⌘ K opens it; typing lists matching auctions and tokens inside it, and the
  page changes only when the reader picks one.
  """
  use Phoenix.LiveView, layout: false

  alias Autolaunch.{HomeMarket, Search}
  alias AutolaunchWeb.Components.MarketCard

  @categories [{"all", "All"}, {"auctions", "Auctions"}, {"tokens", "Tokens"}]
  @chains [{"all", "All chains"}, {"base", "Base"}, {"robinhood", "Robinhood"}]
  @recent_limit 5

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       q: "",
       category: "all",
       chain: "all",
       recent: [],
       opened?: false,
       results: nil,
       results_q: "",
       failed?: false
     )}
  end

  # Nothing is read until the window first opens; the browser keeps the
  # reader's recent searches and hands them over each time it opens.
  def handle_event("open", %{"recent" => recent}, socket) do
    socket = assign(socket, recent: recent_searches(recent))

    if socket.assigns.opened?,
      do: {:noreply, socket},
      else:
        {:noreply,
         socket |> assign(opened?: true) |> MarketCard.assign_figure_rates() |> search()}
  end

  def handle_event("recent", %{"recent" => recent}, socket),
    do: {:noreply, assign(socket, recent: recent_searches(recent))}

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(q: Search.normalize(q)) |> search()}

  def handle_event("category", %{"category" => category}, socket)
      when category in ["all", "auctions", "tokens"],
      do: {:noreply, socket |> assign(category: category) |> search()}

  def handle_event("chain", %{"chain" => chain}, socket)
      when chain in ["all", "base", "robinhood"],
      do: {:noreply, socket |> assign(chain: chain) |> search()}

  def handle_async(:search, {:ok, {q, {:ok, results}}}, socket),
    do: {:noreply, assign(socket, results: results, results_q: q, failed?: false)}

  def handle_async(:search, _failure, socket), do: {:noreply, assign(socket, failed?: true)}

  defp search(socket) do
    %{q: q, category: category, chain: chain} = socket.assigns
    start_async(socket, :search, fn -> {q, read(q, category, chain)} end)
  end

  # "All" shows a few of each; a single kind shows more of it. With nothing
  # typed, auctions come by money raised and tokens newest first.
  defp read(q, category, chain) do
    limit = if category == "all", do: 4, else: 12

    with {:ok, auctions} <- records("auctions", category, q, chain, limit),
         {:ok, tokens} <- records("tokens", category, q, chain, limit) do
      {:ok, %{auctions: auctions, tokens: tokens}}
    end
  end

  defp records(view, category, q, chain, limit) when category in ["all", view] do
    sort = if view == "auctions" and q == "", do: "volume", else: "newest"
    options = HomeMarket.options(%{"view" => view, "q" => q, "chain" => chain, "sort" => sort})

    with {:ok, page} <- HomeMarket.read(options, nil, limit), do: {:ok, page.records}
  end

  defp records(_view, _category, _q, _chain, _limit), do: {:ok, []}

  defp recent_searches(recent) do
    recent
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Search.normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@recent_limit)
  end

  defp all_results_path(q, category, chain) do
    view = if category == "tokens", do: "tokens", else: "auctions"
    HomeMarket.path(HomeMarket.options(%{"view" => view, "q" => q, "chain" => chain}))
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        categories: @categories,
        chains: @chains,
        empty?: match?(%{auctions: [], tokens: []}, assigns.results) and not assigns.failed?
      )

    ~H"""
    <dialog
      :if={!Autolaunch.Prelaunch.read_only?()}
      id="search-dialog"
      class="search-dialog"
      phx-hook="SearchDialog"
      aria-label="Search"
      data-query={@results_q}
      {AutolaunchWeb.Motion.panel("dialog", ["open"])}
    >
      <%!-- The field, not the form, sends the typing: with a change binding on
           the form, LiveView would send the whole form on Enter. Enter opens
           the first result instead (SearchDialog hook). --%>
      <form id="search-dialog-form" class="search-dialog__field" role="search">
        <svg
          viewBox="0 0 24 24"
          width="20"
          height="20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          aria-hidden="true"
        ><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
        <label for="search-dialog-q" class="visually-hidden">
          Search coins, stocks, creators and addresses
        </label>
        <input
          id="search-dialog-q"
          type="search"
          name="q"
          value={@q}
          placeholder="Search coins, stocks, creators and addresses…"
          autocomplete="off"
          phx-change="search"
          phx-debounce="200"
        />
        <button type="button" class="search-dialog__close" data-close-search aria-label="Close search">
          <kbd>Esc</kbd><span>Close</span>
        </button>
      </form>

      <div class="search-dialog__body">
        <div class="search-dialog__categories" role="group" aria-label="Show">
          <button
            :for={{value, label} <- @categories}
            type="button"
            phx-click="category"
            phx-value-category={value}
            aria-pressed={to_string(@category == value)}
          >
            {label}
          </button>
        </div>

        <div class="search-dialog__results">
          <div class="search-dialog__chains" role="group" aria-label="Chain">
            <button
              :for={{value, label} <- @chains}
              type="button"
              phx-click="chain"
              phx-value-chain={value}
              aria-pressed={to_string(@chain == value)}
            >
              {label}
            </button>
          </div>

          <section :if={@q == "" and @recent != []} class="search-dialog__section">
            <header>
              <h2>Recent searches</h2>
              <button type="button" class="search-dialog__clear" data-clear-recent>Clear</button>
            </header>
            <div class="search-dialog__recent">
              <button :for={term <- @recent} type="button" phx-click="search" phx-value-q={term}>
                {term}
              </button>
            </div>
          </section>

          <p :if={is_nil(@results) and not @failed?} class="search-dialog__note">Searching…</p>
          <p :if={@failed?} class="search-dialog__note" role="alert">
            Search is unavailable right now. Try again in a moment.
          </p>
          <p :if={@empty?} class="search-dialog__note">
            {if @results_q == "", do: "Nothing here yet.", else: "Nothing matches “#{@results_q}”."}
          </p>

          <section
            :if={@results && @results.auctions != [] && !@failed?}
            class="search-dialog__section"
          >
            <h2>{if @results_q == "", do: "Top auctions", else: "Auctions"}</h2>
            <MarketCard.search_result
              :for={auction <- @results.auctions}
              kind={:auction}
              record={auction}
              rates={@rates}
            />
          </section>

          <section
            :if={@results && @results.tokens != [] && !@failed?}
            class="search-dialog__section"
          >
            <h2>{if @results_q == "", do: "Newest tokens", else: "Tokens"}</h2>
            <MarketCard.search_result
              :for={token <- @results.tokens}
              kind={:token}
              record={token}
              rates={@rates}
            />
          </section>

          <.link
            :if={@q != ""}
            navigate={all_results_path(@q, @category, @chain)}
            class="search-dialog__all"
            data-search-all
          >
            See all results for “{@q}”
          </.link>
        </div>
      </div>
    </dialog>
    """
  end
end
