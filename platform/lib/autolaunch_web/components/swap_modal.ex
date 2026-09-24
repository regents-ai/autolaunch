defmodule AutolaunchWeb.Components.SwapModal do
  @moduledoc false
  use Phoenix.Component

  attr :id, :string, required: true
  attr :token, :map, required: true
  attr :amount, :string, default: nil, doc: "an amount chosen before the panel opened"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def swap_modal(assigns) do
    assigns = assign(assigns, :presentation, Autolaunch.Token.presentation(assigns.token))

    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      data-record-id={@token.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>Trade {@presentation.symbol}</h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close swap form">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.SwapComponent}
        id={@id <> "-input"}
        launch={%{chain: :base, auction: @token.auction}}
        symbol={@presentation.symbol}
        image={@presentation.image}
        currency={AutolaunchWeb.SwapComponent.entry_symbol(@token.auction)}
        preset_amount={@amount}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :auction, :map, required: true
  attr :amount, :string, default: nil, doc: "an amount chosen before the panel opened"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def bid_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      data-record-id={@auction.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>Bid on {@auction.title}</h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close bid form">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.BidComponent}
        id={@id <> "-input"}
        auction={@auction}
        preset_amount={@amount}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :auction, :map, required: true, doc: "a listed Robinhood auction row"
  attr :amount, :string, default: nil, doc: "an amount chosen before the panel opened"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def robinhood_bid_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      data-record-id={@auction.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>Bid on {@auction.title}</h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close bid form">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.RobinhoodStockBidComponent}
        id={@id <> "-input"}
        auction={@auction.auction_address}
        preset_amount={@amount}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end
end
