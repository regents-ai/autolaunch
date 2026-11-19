defmodule AutolaunchWeb.ExposurePortfolioComponent do
  @moduledoc """
  The portfolio's Isolated Exposure to After-hours Stocks: for each series the site offers, what
  the signed-in wallet holds of its two tokens and what they are worth at the
  series' last price, each read now from the chain
  (`Autolaunch.Exposure.exposure_holdings/3`), with a link to the series or
  its Redeem tab when the position can redeem. Series the wallet holds nothing of are left out.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.Deployment
  alias AutolaunchWeb.ExposureFormat, as: F
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, holdings: AsyncResult.loading(), read_for: nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.read_for == socket.assigns.current_human_id,
      do: {:ok, socket},
      else:
        {:ok,
         socket
         |> assign(read_for: socket.assigns.current_human_id, holdings: AsyncResult.loading())
         |> read()}
  end

  @impl true
  def handle_event("retry_holdings", _params, socket), do: {:noreply, read(socket)}

  @impl true
  def handle_async(:holdings, {:ok, read}, socket),
    do: {:noreply, assign(socket, holdings: AsyncResult.ok(socket.assigns.holdings, read))}

  def handle_async(:holdings, {:exit, reason}, socket),
    do: {:noreply, assign(socket, holdings: AsyncResult.failed(socket.assigns.holdings, reason))}

  defp read(socket) do
    actor = %Human{human_account_id: socket.assigns.current_human_id}

    socket
    |> assign(holdings: AsyncResult.loading(socket.assigns.holdings, true))
    |> start_async(:holdings, fn -> read_positions(actor) end)
  end

  defp read_positions(actor) do
    with {:ok, %{series: all}} <- Deployment.current() do
      {kept, unread} =
        Enum.reduce(all, {[], 0}, fn address, counts ->
          count_holding(Exposure.exposure_holdings(address, %{}, actor: actor), counts)
        end)

      {:ok, kept, unread, length(all)}
    end
  end

  defp count_holding({:ok, holding}, {kept, unread}) do
    if held?(holding), do: {[holding | kept], unread}, else: {kept, unread}
  end

  defp count_holding({:error, _reason}, {kept, unread}), do: {kept, unread + 1}

  defp held?(holding), do: holding.overnight + holding.session > 0

  @impl true
  def render(assigns) do
    {positions, unread, total} =
      case assigns.holdings.result do
        {:ok, positions, unread, total} -> {positions, unread, total}
        _no_read -> {[], 0, 0}
      end

    assigns = assign(assigns, positions: positions, unread: unread, total: total)

    ~H"""
    <section id={@id} class="portfolio__section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="portfolio__title">Isolated Exposure to After-hours Stocks</h2>
      <div
        :if={@holdings.failed || match?({:error, _}, @holdings.result) || @unread > 0}
        class="portfolio__hint"
      >
        <span role="alert">
          <%= if @unread > 0 && @unread < @total && !@holdings.failed do %>
            Some series couldn't be read. Showing the positions that loaded.
          <% else %>
            Your After-hours and Market-hours tokens couldn't be read just now.
          <% end %>
        </span>
        <button
          type="button"
          class="rg-button rg-button--secondary"
          phx-click="retry_holdings"
          phx-target={@myself}
          disabled={!!@holdings.loading}
        >
          Retry
        </button>
      </div>
      <div :if={@holdings.loading} class="market-list__scroll" aria-busy="true">
        <span class="loading-block"></span>
      </div>
      <div :if={@positions != []} class="market-list__scroll">
        <table class="market-list__table exposure__table">
          <caption class="visually-hidden">Your After-hours and Market-hours tokens</caption>
          <thead>
            <tr>
              <th scope="col">Series</th>
              <th scope="col">After-hours</th>
              <th scope="col">Market-hours</th>
              <th scope="col">Value</th>
              <th scope="col"><span class="visually-hidden">Action</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={holding <- @positions} id={"#{@id}-#{holding.series.address}"}>
              <td data-label="Series">
                {holding.series.stock.symbol} to {F.moment(List.last(holding.series.boundaries))}
              </td>
              <td data-label="After-hours">
                {F.tokens(holding.overnight, holding.series.stock.decimals)}
              </td>
              <td data-label="Market-hours">
                {F.tokens(holding.session, holding.series.stock.decimals)}
              </td>
              <td data-label="Value">{value(holding)}</td>
              <td class="exposure__row-action">
                <.link
                  navigate={series_path(holding)}
                  class="rg-button rg-button--secondary"
                >
                  {if redeemable?(holding), do: "Redeem", else: "View series"}
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div
        :if={match?({:ok, [], 0, _}, @holdings.result)}
        class="market-list__scroll market-list__empty"
      >
        <h2>No tokens yet</h2>
        <p>After-hours and Market-hours tokens you mint or buy appear here.</p>
        <.link navigate={~p"/stock/isolated-afters"} class="rg-button rg-button--secondary">
          Mint tokens
        </.link>
      </div>
    </section>
    """
  end

  defp redeemable?(%{redeemable: %{overnight: overnight, session: session}}),
    do: overnight > 0 or session > 0

  defp series_path(holding) do
    query = [series: holding.series.address]
    query = if redeemable?(holding), do: query ++ [tab: "redeem"], else: query
    ~p"/stock/isolated-afters?#{query}"
  end

  # Before the first close no price has been applied, so the tokens have no value
  # yet. After the end they are worth the stock a return pays now.
  defp value(%{series: %{settled: 0}}), do: "—"

  defp value(%{series: %{status: :ended} = series, redeemable: %{paid: paid}}),
    do: "#{F.tokens(paid, series.stock.decimals)} #{series.stock.symbol}"

  defp value(%{series: series} = holding) do
    unit = Integer.pow(10, series.stock.decimals)
    F.usd(div(holding.overnight * series.night + holding.session * series.day, unit))
  end
end
