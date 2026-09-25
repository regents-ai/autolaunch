defmodule AutolaunchWeb.Components.BidPlaced do
  @moduledoc """
  What a bid panel shows once its bid is placed: the news, the transaction on
  the chain's explorer, the way back to the auction and the portfolio, and a
  window to share it on X (`AutolaunchWeb.Components.ShareDialog`).

  The host component owns two events that read the bidder's X account:
  `share_opened` when the window opens, and `refresh_x_connections` (sent
  here by the X connect button) once they connect one.
  """
  use Phoenix.Component
  use AutolaunchWeb, :verified_routes

  alias Autolaunch.Accounts.XOAuth
  alias AutolaunchWeb.Components.ShareDialog

  @doc "The bidder's personal X connection, connected or not."
  def profile_x(connections), do: Enum.find(connections, &(&1.role == :profile))

  attr :id, :string, required: true
  attr :target, :any, required: true
  attr :token_symbol, :string, required: true
  attr :chain, :atom, required: true, values: [:base, :robinhood]
  attr :hash, :string, default: nil, doc: "the bid transaction"
  attr :test_chain, :boolean, default: false
  attr :auction_path, :string, required: true
  attr :auction_url, :string, required: true
  attr :share_image, :string, required: true, doc: "the auction's share picture"
  attr :x_connection, :map, default: nil, doc: "the bidder's personal X connection"
  attr :x_enabled, :boolean, default: false

  def bid_placed(assigns) do
    assigns = assign(assigns, :x_account, connected(assigns.x_connection))

    ~H"""
    <div class="bid-placed" role="status">
      <p class="bid-placed__news">
        Your bid on <span class="ticker">{@token_symbol}</span> was placed successfully.
      </p>
      <p :if={@test_chain} class="bid-form__note">
        This was on a test network. Test assets have no real value.
      </p>
      <a
        :if={@hash && !@test_chain}
        href={transaction_url(@chain, @hash)}
        target="_blank"
        rel="noopener noreferrer"
      >
        View on {explorer(@chain)} ↗
      </a>

      <div class="bid-placed__actions">
        <.link navigate={@auction_path} class="rg-button rg-button--secondary">
          <span class="rg-button__label">View Auction</span>
        </.link>
        <.link navigate={~p"/portfolio"} class="rg-button rg-button--secondary">
          <span class="rg-button__label">View Portfolio</span>
        </.link>
        <ShareDialog.share_dialog
          id={"#{@id}-share"}
          message={"Bidding #{@token_symbol} on autolaunch.sh #{@auction_url}"}
          image={@share_image}
          phx-click="share_opened"
          phx-target={@target}
        >
          <:account>
            <div
              id={"#{@id}-x"}
              class="share-x__account"
              phx-hook="XConnections"
              data-x-oauth-origin={XOAuth.origin()}
              data-x-refresh-here
            >
              <p :if={@x_account}>Connected as @{@x_account.username}</p>
              <div
                :if={!@x_account}
                data-x-role="profile"
                data-x-intent-sequence={intent_sequence(@x_connection)}
              >
                <p :if={@x_enabled}>Connect your X account to share from it.</p>
                <p :if={!@x_enabled}>X accounts can't be connected right now.</p>
                <Regent.Primitives.button
                  :if={@x_enabled}
                  type="button"
                  data-x-connect-role="profile"
                  variant="secondary"
                >
                  Connect X
                </Regent.Primitives.button>
              </div>
              <p data-x-connection-status role="status" aria-live="polite"></p>
            </div>
          </:account>
        </ShareDialog.share_dialog>
      </div>
    </div>
    """
  end

  @doc "The chain's explorer page for a transaction."
  def transaction_url(:base, hash), do: "https://basescan.org/tx/#{hash}"
  def transaction_url(:robinhood, hash), do: "https://robinhoodchain.blockscout.com/tx/#{hash}"

  @doc "The chain's explorer page for an address."
  def address_url(:base, address), do: "https://basescan.org/address/#{address}"

  def address_url(:robinhood, address),
    do: "https://robinhoodchain.blockscout.com/address/#{address}"

  @doc "The name of the chain's explorer."
  def explorer(:base), do: "Basescan"
  def explorer(:robinhood), do: "Blockscout"

  defp connected(%{verified_at: %DateTime{}, username: username} = connection)
       when is_binary(username),
       do: connection

  defp connected(_connection), do: nil

  defp intent_sequence(%{intent_sequence: sequence}) when is_integer(sequence), do: sequence
  defp intent_sequence(_connection), do: 0
end
