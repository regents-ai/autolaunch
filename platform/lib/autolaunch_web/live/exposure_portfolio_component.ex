defmodule AutolaunchWeb.ExposurePortfolioComponent do
  @moduledoc """
  The portfolio's After-hours Exposure: for each series the site offers, what
  the signed-in wallet holds of its two tokens and what they are worth at the
  series' last price, each read now from the chain
  (`Autolaunch.Exposure.exposure_holdings/3`), with a link to the series'
  Return tab. Series the wallet holds nothing of are left out.
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
      {:ok, %{series: all}} = Deployment.current()

      all
      |> Enum.reverse()
      |> Enum.map(&Exposure.exposure_holdings(&1, %{}, actor: actor))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, holding}, {:ok, kept} -> {:cont, {:ok, [holding | kept]}}
        {:error, error}, _kept -> {:halt, {:error, Exposure.reason(error)}}
      end)
      |> case do
        {:ok, kept} -> {:ok, kept |> Enum.reverse() |> Enum.filter(&held?/1)}
        error -> error
      end
    end)
  end

  defp held?(holding), do: holding.overnight + holding.session > 0

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="portfolio__section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="portfolio__title">After-hours Exposure</h2>
      <p
        :if={@holdings.failed || match?({:error, _}, @holdings.result)}
        class="portfolio__hint"
        role="alert"
      >
        Your After-hours Exposure tokens couldn't be read just now.
      </p>
      <div :if={@holdings.loading} class="market-list__scroll" aria-busy="true">
        <span class="loading-block"></span>
      </div>
      <div :if={match?({:ok, [_ | _]}, @holdings.result)} class="market-list__scroll">
        <table class="market-list__table exposure__table">
          <caption class="visually-hidden">Your After-hours Exposure tokens</caption>
          <thead>
            <tr>
              <th scope="col">Series</th>
              <th scope="col">After-hours</th>
              <th scope="col">Market-hours</th>
              <th scope="col">Value</th>
              <th scope="col"><span class="visually-hidden">Return</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={holding <- elem(@holdings.result, 1)} id={"#{@id}-#{holding.series.address}"}>
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
                  navigate={~p"/after-hour-stocks?#{[series: holding.series.address, tab: "return"]}"}
                  class="rg-button rg-button--secondary"
                >
                  Return
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <div :if={@holdings.result == {:ok, []}} class="market-list__scroll market-list__empty">
        <h2>No tokens yet</h2>
        <p>After-hours and Market-hours tokens you mint or buy appear here.</p>
        <.link navigate={~p"/after-hour-stocks"} class="rg-button rg-button--secondary">
          After-hours Exposure
        </.link>
      </div>
    </section>
    """
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
