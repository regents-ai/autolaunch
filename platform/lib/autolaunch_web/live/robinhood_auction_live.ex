defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood memestock auction, named by its address. The chain is the only
  record of these auctions, so the page holds no listing of its own: it names
  the auction and hands the signed-in wallet the bid step.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.Lab

  def mount(_params, _session, socket), do: {:ok, assign(socket, :open?, Lab.enabled?())}

  def handle_params(%{"auction" => auction}, _uri, socket) do
    case Address.normalize(auction) do
      {:ok, address} -> {:noreply, assign(socket, :auction, address)}
      :error -> {:noreply, assign(socket, :auction, nil)}
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
        <p>
          A memestock pair auction on the Robinhood test network. Test assets have no real value.
        </p>
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
end
