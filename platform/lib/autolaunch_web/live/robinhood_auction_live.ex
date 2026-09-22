defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood memestock auction, named by its address. The chain is the only
  record of these auctions, so the page holds no listing of its own: it names
  the auction, hands the signed-in wallet the bid step, and once the launch
  has graduated, points at the token's own page, where it trades and stakes.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.{Auctions, Lab}

  def mount(_params, _session, socket), do: {:ok, assign(socket, :open?, Lab.configured?())}

  def handle_params(%{"auction" => auction}, _uri, socket) do
    case Address.normalize(auction) do
      {:ok, address} -> {:noreply, socket |> assign(:auction, address) |> load_launch()}
      :error -> {:noreply, assign(socket, auction: nil, launch: %Phoenix.LiveView.AsyncResult{})}
    end
  end

  def render(assigns) do
    ~H"""
    <article :if={@open? && @auction} id="autolaunch-robinhood-auction" class="autolaunch-page">
      <header class="autolaunch-heading">
        <.link navigate="/auctions" class="market-back">← Auctions</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Robinhood auction</h1>
        </Regent.Structure.section_bar>
        <p>{network_copy(Lab.test_chain?())}</p>
        <p class="launch-wallet-mono">{@auction}</p>
      </header>
      <.live_component
        module={AutolaunchWeb.RobinhoodStockBidComponent}
        id="autolaunch-robinhood-bid"
        auction={@auction}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <p :if={graduated(@launch)} id="robinhood-token-link" class="autolaunch-live-market">
        This auction graduated.
        <.link navigate={"/robinhood/tokens/#{graduated(@launch).token}"}>
          Open {graduated(@launch).symbol}, its token, to stake it
        </.link>
      </p>
    </article>

    <section
      :if={!@open? || !@auction}
      id="autolaunch-robinhood-auction"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Auction not found</h1>
      </Regent.Structure.section_bar>
      <p :if={!@open?}>Robinhood auctions are not open on this site yet.</p>
      <p :if={@open? && !@auction}>That is not an auction address.</p>
      <.link navigate="/auctions">Return to Auctions</.link>
    </section>
    """
  end

  # The launch record is its own read of the chain, beside the bid card's: it
  # says whether the launch has graduated, and so whether the token's page
  # exists. A page that cannot read it shows the bid card alone.
  defp load_launch(%{assigns: %{open?: false}} = socket),
    do: assign(socket, :launch, %Phoenix.LiveView.AsyncResult{})

  defp load_launch(socket) do
    auction = socket.assigns.auction

    assign_async(
      socket,
      :launch,
      fn -> with {:ok, launch} <- Auctions.fetch(auction), do: {:ok, %{launch: launch}} end,
      reset: true
    )
  end

  defp graduated(%{ok?: true, result: %{state: :graduated} = launch}), do: launch
  defp graduated(_launch), do: nil

  defp network_copy(true),
    do: "A memestock pair auction on the Robinhood test network. Test assets have no real value."

  defp network_copy(false), do: "A memestock pair auction on Robinhood Chain."
end
