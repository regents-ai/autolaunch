defmodule AutolaunchWeb.EarnPortfolioComponent do
  @moduledoc """
  The portfolio's Earn: for each product, what the signed-in wallet has lent
  in it, read now from the chain at the latest block
  (`Autolaunch.Earn.read_earn_position/3`), with a link to /earn: Withdraw for
  a balance, Deposit for none. A balance of any size, a single smallest unit
  included, is a balance. The page's Refresh reads it again
  (`send_update(id: ..., read: true)`), and while it reads the figures before
  are not shown.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Earn
  alias Autolaunch.Earn.Catalog
  alias AutolaunchWeb.EarnComponent
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(socket), do: {:ok, assign(socket, positions: AsyncResult.loading(), read_for: nil)}

  @impl true
  def update(%{read: true}, socket), do: {:ok, read(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.read_for == socket.assigns.current_human_id,
      do: {:ok, socket},
      else: {:ok, socket |> assign(read_for: socket.assigns.current_human_id) |> read()}
  end

  @impl true
  def handle_async(:positions, {:ok, read}, socket),
    do: {:noreply, assign(socket, positions: AsyncResult.ok(read))}

  def handle_async(:positions, {:exit, reason}, socket),
    do: {:noreply, assign(socket, positions: AsyncResult.failed(AsyncResult.loading(), reason))}

  # A new read stops the one still running, so asks never stack.
  defp read(socket) do
    actor = %Human{human_account_id: socket.assigns.current_human_id}

    socket
    |> assign(positions: AsyncResult.loading())
    |> cancel_async(:positions)
    |> start_async(:positions, fn ->
      Enum.map(Catalog.products(), &{&1, Earn.read_earn_position(&1.id, %{}, actor: actor)})
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="portfolio__section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="portfolio__title">Earn</h2>
      <p :if={@positions.failed} class="portfolio__hint" role="alert">
        Your Earn balances couldn't be read just now.
      </p>
      <div :if={@positions.loading} class="market-list__scroll" aria-busy="true">
        <span class="loading-block"></span>
      </div>
      <ul :if={@positions.ok?} class="earn-portfolio__rows">
        <li
          :for={{product, read} <- @positions.result}
          id={"#{@id}-#{product.id}"}
          class="earn-portfolio__row"
        >
          <div>
            <strong>{product.asset}</strong>
            <p class="earn-portfolio__muted">{product.market}</p>
          </div>
          <.held id={"#{@id}-#{product.id}"} product={product} read={read} />
        </li>
      </ul>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :product, :map, required: true
  attr :read, :any, required: true

  defp held(%{read: {:ok, %{holding: %{position: {:held, balance}}, terms: terms}}} = assigns) do
    assigns = assign(assigns, balance: balance, terms: terms)

    ~H"""
    <div class="earn-portfolio__held">
      <strong id={"#{@id}-balance"}>{EarnComponent.amount(@balance, @product.decimals, @product.asset)}</strong>
      <p class="earn-portfolio__muted">Read at block {Integer.to_string(@terms.block.number)}</p>
    </div>
    <.link navigate={~p"/earn?tab=withdraw"} class="rg-button rg-button--secondary">Withdraw</.link>
    """
  end

  defp held(%{read: {:ok, %{holding: %{position: :none}}}} = assigns) do
    ~H"""
    <p id={"#{@id}-balance"} class="earn-portfolio__muted">Nothing lent yet.</p>
    <.link navigate={~p"/earn"} class="rg-button rg-button--secondary">Deposit</.link>
    """
  end

  defp held(%{read: {:error, _error}} = assigns) do
    ~H"""
    <p id={"#{@id}-balance"} class="earn-portfolio__muted" role="alert">
      Couldn't be read just now.
    </p>
    """
  end
end
