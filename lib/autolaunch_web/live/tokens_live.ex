defmodule AutolaunchWeb.TokensLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.{Swaps, Tokens}
  alias AutolaunchWeb.Format
  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 30_000
  @tokens_css_path Path.expand("../../../assets/css/tokens-live.css", __DIR__)
  @external_resource @tokens_css_path
  @tokens_css File.read!(@tokens_css_path)
  @default_filters %{"search" => "", "sort" => "trending"}
  @allowed_sorts ~w(trending newest top_raise)

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> Refreshable.subscribe([:tokens, :system])
     |> assign(:page_title, "Revsplit Tokens")
     |> assign(:active_view, "tokens")
     |> assign(:swaps_available, Swaps.available?())}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, assign_tokens(socket, Map.merge(@default_filters, params))}
  end

  def handle_event("filters_changed", %{"filters" => filters}, socket) do
    merged = Map.merge(socket.assigns.filters, filters)

    {:noreply, push_patch(socket, to: ~p"/tokens?#{filter_query(merged)}")}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_tokens/1)}
  end

  def handle_info({:autolaunch_live_update, :changed}, socket) do
    {:noreply, reload_tokens(socket)}
  end

  def render(assigns) do
    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <style id="tokens-live-css">
        <%= Phoenix.HTML.raw(route_css()) %>
      </style>

      <section id="revsplit-tokens" class="al-tokens-route">
        <header class="al-tokens-toolbar">
          <div class="al-tokens-tabs" aria-label="Token views">
            <.link patch={~p"/tokens"} class={["al-tokens-tab", @filters["sort"] == "trending" && "is-active"]}>
              <.tokens_icon name="flame" />
              <span>Trending</span>
            </.link>
            <.link patch={~p"/tokens?#{%{sort: "newest"}}"} class={["al-tokens-tab", @filters["sort"] == "newest" && "is-active"]}>
              <.tokens_icon name="new" />
              <span>New</span>
            </.link>
            <.link patch={~p"/tokens?#{%{sort: "top_raise"}}"} class={["al-tokens-tab", @filters["sort"] == "top_raise" && "is-active"]}>
              <.tokens_icon name="top" />
              <span>Top raise</span>
            </.link>
          </div>

          <form phx-change="filters_changed" class="al-tokens-search" role="search">
            <input type="hidden" name="filters[sort]" value={@filters["sort"]} />
            <label for="revsplit-token-search" class="sr-only">Search Revsplit Tokens</label>
            <input
              id="revsplit-token-search"
              type="search"
              name="filters[search]"
              value={@filters["search"]}
              placeholder="Search tokens or agents"
            />
          </form>
        </header>

        <div class="al-tokens-table-shell">
          <table class="al-tokens-table">
            <thead>
              <tr>
                <th></th>
                <th>Token</th>
                <th>Price</th>
                <th>Auction raise</th>
                <th>Goal</th>
                <th>FDV</th>
                <th>Revsplit</th>
                <th>Graduated</th>
                <th>Updated</th>
                <th :if={@swaps_available}>Trade</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@tokens == []}>
                <td colspan={if @swaps_available, do: 10, else: 9}>
                  <div class="al-tokens-empty">
                    <strong>No graduated tokens yet.</strong>
                    <p>Graduated auction tokens will appear here after the market clears.</p>
                  </div>
                </td>
              </tr>
              <tr :for={token <- @tokens} id={token.id}>
                <td class="al-tokens-favorite">☆</td>
                <td>
                  <.link navigate={token.detail_url} class="al-tokens-token-cell">
                    <span class="al-tokens-avatar">{token_mark(token)}</span>
                    <span>
                      <strong>{token.agent_name}</strong>
                      <small>{display_symbol(token.token_symbol)}</small>
                    </span>
                  </.link>
                </td>
                <td class="al-tokens-number">{format_quote(token.price_quote, 6)}</td>
                <td class="al-tokens-number">{format_quote(token.auction_raise_quote, 1)}</td>
                <td class="al-tokens-number">{format_quote(token.required_raise_quote, 1)}</td>
                <td class="al-tokens-number">{format_quote(token.fdv_quote, 1)}</td>
                <td>
                  <span class="al-tokens-status">{revsplit_label(token.revsplit_status)}</span>
                </td>
                <td>{display_date(token.graduated_at)}</td>
                <td>{display_date(token.last_synced_at)}</td>
                <td :if={@swaps_available}>
                  <button
                    :if={swap_token_ready?(token)}
                    type="button"
                    class="al-token-swap-button"
                    data-swap-open
                    data-swap-side="buy"
                    data-swap-chain-id={token.chain_id}
                    data-swap-token={token.token_address}
                    data-swap-symbol={display_symbol(token.token_symbol)}
                    data-swap-agent={token.agent_name}
                  >
                    Buy
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <.swap_modal :if={@swaps_available} />

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  attr :name, :string, required: true

  defp tokens_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <%= case @name do %>
        <% "flame" -> %>
          <path d="M12 21c3.4 0 6-2.4 6-5.9c0-2.3-1.2-4-3-5.6c-.9 2.1-2.1 3.2-3.6 3.5c1-2.8.3-5.6-2.2-8c-.2 2.6-1.3 4.2-2.6 5.9C5.5 12.4 5 13.8 5 15.3C5 18.7 7.7 21 12 21Z" />
        <% "new" -> %>
          <path d="M4 16.5h16" />
          <path d="M6.5 16.5a5.5 5.5 0 0 1 11 0" />
          <path d="M12 4v5" />
          <path d="M8.5 7.5L12 4l3.5 3.5" />
        <% "top" -> %>
          <path d="M6 20h12" />
          <path d="M8 17V9" />
          <path d="M12 17V5" />
          <path d="M16 17v-6" />
        <% _ -> %>
          <circle cx="12" cy="12" r="8" />
      <% end %>
    </svg>
    """
  end

  defp assign_tokens(socket, filters) do
    filters = sanitize_filters(filters)
    tokens = tokens_module().list_revsplit_tokens(filters)

    socket
    |> assign(:filters, filters)
    |> assign(:tokens, tokens)
  end

  defp reload_tokens(socket), do: assign_tokens(socket, socket.assigns.filters)

  defp sanitize_filters(filters) do
    %{
      "search" => filters |> Map.get("search", "") |> to_string() |> String.trim(),
      "sort" => sanitize_sort(Map.get(filters, "sort"))
    }
  end

  defp sanitize_sort(sort) when sort in @allowed_sorts, do: sort
  defp sanitize_sort(_sort), do: @default_filters["sort"]

  defp filter_query(filters) do
    filters
    |> Enum.reject(fn {key, value} ->
      Map.get(@default_filters, key) == value or value in [nil, ""]
    end)
    |> Map.new()
  end

  defp token_mark(%{token_symbol: symbol}) when is_binary(symbol) and symbol != "",
    do: symbol |> String.slice(0, 2) |> String.upcase()

  defp token_mark(%{agent_name: name}) when is_binary(name) do
    name
    |> String.split(~r/[\s-]+/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end

  defp token_mark(_token), do: "RT"

  defp display_symbol(nil), do: "REV"
  defp display_symbol(""), do: "REV"
  defp display_symbol(symbol), do: symbol

  defp format_quote(nil, _places), do: "Not available"

  defp format_quote(value, places) do
    case Format.parse_decimal(value) do
      nil ->
        "Not available"

      decimal ->
        decimal
        |> Decimal.round(places)
        |> Format.decimal_to_string(places)
        |> Format.add_delimiters()
        |> Kernel.<>(" $REGENT")
    end
  end

  defp display_date(nil), do: "Not available"
  defp display_date(value), do: Format.display_chart_date(value)

  defp revsplit_label("active"), do: "Active"
  defp revsplit_label("paused"), do: "Paused"
  defp revsplit_label("retired"), do: "Retired"
  defp revsplit_label(value), do: Format.humanize_key(value)

  defp swap_token_ready?(token) do
    token.revsplit_status == "active" and Swaps.available?(token.chain_id) and
      is_binary(token.token_address)
  end

  defp swap_modal(assigns) do
    ~H"""
    <div id="token-swap-modal" class="al-swap-modal" phx-hook="SwapModal" phx-update="ignore" hidden>
      <div class="al-swap-backdrop" data-swap-close></div>
      <section class="al-swap-dialog" data-swap-dialog tabindex="-1" role="dialog" aria-modal="true" aria-labelledby="token-swap-title">
        <div class="al-swap-head">
          <div>
            <p class="al-kicker">Base swap</p>
            <h2 id="token-swap-title" data-swap-title>Trade token</h2>
            <p data-swap-copy>Choose an amount to quote through Uniswap v4.</p>
          </div>
          <button type="button" class="al-swap-close" data-swap-close aria-label="Close">×</button>
        </div>

        <div class="al-swap-form">
          <label>
            <span>Amount</span>
            <input data-swap-amount inputmode="decimal" autocomplete="off" />
          </label>
          <label>
            <span>Slippage %</span>
            <input data-swap-slippage inputmode="decimal" autocomplete="off" value="1" />
          </label>
        </div>

        <div class="al-swap-quote" data-swap-quote-panel hidden></div>
        <p class="al-swap-notice" data-swap-notice hidden></p>

        <div class="al-swap-actions">
          <button type="button" class="al-ghost" data-swap-connect>Connect wallet</button>
          <button type="button" class="al-ghost" data-swap-quote>Get quote</button>
          <button type="button" class="al-submit" data-swap-submit>Swap</button>
        </div>
      </section>
    </div>
    """
  end

  defp tokens_module do
    :autolaunch
    |> Application.get_env(:tokens_live, [])
    |> Keyword.get(:tokens_module, Tokens)
  end

  defp route_css, do: @tokens_css
end
