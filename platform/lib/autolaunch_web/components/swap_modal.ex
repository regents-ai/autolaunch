defmodule AutolaunchWeb.Components.SwapModal do
  @moduledoc false
  use Phoenix.Component

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias AutolaunchWeb.SwapComponent
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :token, :map, required: true, doc: "a launched token with its auction loaded"
  attr :direction, :atom, default: :buy, values: [:buy, :sell], doc: "the side the form opens on"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def swap_modal(assigns) do
    assigns =
      assign(assigns,
        presentation: Autolaunch.Token.presentation(assigns.token),
        pool: pool(assigns.token.auction)
      )

    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
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
        module={SwapComponent}
        id={@id <> "-input"}
        launch={@pool.launch}
        symbol={@presentation.symbol}
        image={@presentation.image}
        currency={@pool.currency}
        start_direction={@direction}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end

  # The pool a token trades in and the currency it is entered with: a
  # Robinhood token's pool is named by its auction's address.
  defp pool(auction) do
    if RobinhoodLab.chain?(auction.chain_id),
      do: %{
        launch: %{chain: :robinhood, auction: auction.auction_address},
        currency: auction.quote_token_symbol
      },
      else: %{
        launch: %{chain: :base, auction: auction},
        currency: SwapComponent.entry_symbol(auction)
      }
  end

  @doc "Whether a launched token, with its auction loaded, can be swapped from this site."
  def tradable?(%{auction: auction}) do
    if RobinhoodLab.chain?(auction.chain_id),
      do: RobinhoodLab.swap_configured?(),
      else: not is_nil(SwapComponent.entry_symbol(auction))
  end

  attr :id, :string, required: true
  attr :auction, :map, required: true
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def bid_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
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
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :auction, :map, required: true, doc: "a listed Robinhood auction row"

  attr :ended, :string,
    default: nil,
    doc: "what the auction's end means for bidders; the dialog then settles the wallet's bids"

  attr :stake_path, :string, default: nil, doc: "where claimed tokens are staked"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  def robinhood_bid_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-record-id={@auction.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>
          {if @ended, do: "Your bids on #{@auction.title}", else: "Bid on #{@auction.title}"}
        </h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close bid form">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.RobinhoodStockBidComponent}
        id={@id <> "-input"}
        auction={@auction.auction_address}
        launch={@auction}
        ended={@ended}
        stake_path={@stake_path}
        token_symbol={@auction.token_symbol}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :position, :map, required: true, doc: "a stored Base bid with its auction loaded"
  attr :market, :map, default: nil, doc: "the market feed's reading of the bid's auction"
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil

  @doc "One ended Base bid's settlement card, for withdrawing its money or claiming its tokens."
  def settlement_modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-record-id={@position.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>Your bid on {@position.auction.title}</h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.BidSettlementComponent}
        id={@id <> "-input"}
        position={@position}
        market={@market}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </dialog>
    """
  end
end
