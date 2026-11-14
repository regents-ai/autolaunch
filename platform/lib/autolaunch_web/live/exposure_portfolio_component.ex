defmodule AutolaunchWeb.ExposurePortfolioComponent do
  @moduledoc """
  The portfolio's Isolated Exposure to After-hours Stocks: for this week and
  the last eight weeks that opened, what the signed-in wallet holds of each
  week's two tokens and what they are worth at its last price, read now from
  the chain in one go (`Autolaunch.Exposure.exposure_portfolio/1`), with a
  link to the week's Redeem tab. Weeks the wallet holds nothing of are left
  out.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Exposure
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
      else: {:ok, socket |> assign(read_for: socket.assigns.current_human_id) |> read()}
  end

  @impl true
  def handle_async(:holdings, {:ok, read}, socket),
    do: {:noreply, assign(socket, holdings: AsyncResult.ok(socket.assigns.holdings, read))}

  def handle_async(:holdings, {:exit, reason}, socket),
    do: {:noreply, assign(socket, holdings: AsyncResult.failed(socket.assigns.holdings, reason))}

  defp read(socket) do
    actor = %Human{human_account_id: socket.assigns.current_human_id}

    start_async(socket, :holdings, fn ->
      case Exposure.exposure_portfolio(actor: actor) do
        {:ok, holdings} -> {:ok, holdings}
        {:error, error} -> {:error, Exposure.reason(error)}
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="portfolio__section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="portfolio__title">Isolated Exposure to After-hours Stocks</h2>
      <p
        :if={@holdings.failed || match?({:error, _}, @holdings.result)}
        class="portfolio__hint"
        role="alert"
      >
        Your After-hours and Market-hours tokens couldn't be read just now.
      </p>
      <div :if={@holdings.loading} class="market-list__scroll" aria-busy="true">
        <span class="loading-block"></span>
      </div>
      <div :if={match?({:ok, [_ | _]}, @holdings.result)} class="market-list__scroll">
        <table class="market-list__table exposure__table">
          <caption class="visually-hidden">Your After-hours and Market-hours tokens</caption>
          <thead>
            <tr>
              <th scope="col">Week</th>
              <th scope="col">After-hours</th>
              <th scope="col">Market-hours</th>
              <th scope="col">Value</th>
              <th scope="col"><span class="visually-hidden">Redeem</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={holding <- elem(@holdings.result, 1)} id={"#{@id}-#{holding.week.week}"}>
              <td data-label="Week">
                {holding.week.stock.symbol} to {F.moment(List.last(holding.week.boundaries))}
              </td>
              <td data-label="After-hours">
                {F.tokens(holding.overnight, holding.week.stock.decimals)}
              </td>
              <td data-label="Market-hours">
                {F.tokens(holding.session, holding.week.stock.decimals)}
              </td>
              <td data-label="Value">{value(holding)}</td>
              <td class="exposure__row-action">
                <.link
                  navigate={
                    ~p"/stock/isolated-afters?#{[week: holding.week.week, tab: "redeem"]}"
                  }
                  class="rg-button rg-button--secondary"
                >
                  Redeem
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={@holdings.result == {:ok, []}} class="market-list__scroll market-list__empty">
        <h2>No tokens yet</h2>
        <p>After-hours and Market-hours tokens you deposit for or buy appear here.</p>
        <.link navigate={~p"/stock/isolated-afters"} class="rg-button rg-button--secondary">
          Deposit
        </.link>
      </div>
    </section>
    """
  end

  # Before the first price applies the tokens have no value yet. After the end
  # they are worth the stock a redemption pays now.
  defp value(%{week: %{applied: 0}}), do: "—"

  defp value(%{week: %{status: :ended} = week, redeemable: %{paid: paid}}),
    do: "#{F.tokens(paid, week.stock.decimals)} #{week.stock.symbol}"

  defp value(%{week: week} = holding) do
    unit = Integer.pow(10, week.stock.decimals)
    F.usd(div(holding.overnight * week.night + holding.session * week.day, unit))
  end
end
