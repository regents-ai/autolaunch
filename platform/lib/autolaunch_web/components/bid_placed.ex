defmodule AutolaunchWeb.Components.BidPlaced do
  @moduledoc """
  What a bid panel shows once its bid is placed: the news, the transaction on
  the chain's explorer, the way back to the auction and the portfolio, and a
  post to share it on X.

  Sharing only opens X's own composer with the message filled in; nothing is
  ever posted for the bidder. The host component owns three events:
  `share_bid` opens the message, `share_message_changed` carries its edits,
  and `refresh_x_connections` (sent here by the X connect button) reloads the
  bidder's X account.
  """
  use Phoenix.Component
  use AutolaunchWeb, :verified_routes

  alias Autolaunch.Accounts.XOAuth

  @doc "The message a share starts with."
  def message(token_symbol, auction_url),
    do: "Bidding #{token_symbol} on autolaunch.sh #{auction_url}"

  @doc "The bidder's personal X connection, connected or not."
  def profile_x(connections), do: Enum.find(connections, &(&1.role == :profile))

  attr :id, :string, required: true
  attr :target, :any, required: true
  attr :token_symbol, :string, required: true
  attr :chain, :atom, required: true, values: [:base, :robinhood]
  attr :hash, :string, default: nil, doc: "the bid transaction"
  attr :test_chain, :boolean, default: false
  attr :auction_path, :string, required: true
  attr :sharing, :boolean, default: false
  attr :message, :string, default: ""
  attr :x_connection, :map, default: nil, doc: "the bidder's personal X connection"
  attr :x_enabled, :boolean, default: false

  def bid_placed(assigns) do
    assigns = assign(assigns, :x_account, connected(assigns.x_connection))

    ~H"""
    <div class="bid-placed" role="status">
      <p class="bid-placed__news">Your bid on ${@token_symbol} was placed successfully.</p>
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
        <Regent.Primitives.button
          :if={!@sharing}
          type="button"
          phx-click="share_bid"
          phx-target={@target}
          variant="secondary"
        >
          Share on X
        </Regent.Primitives.button>
      </div>

      <div :if={@sharing} class="bid-share">
        <div
          id={"#{@id}-x"}
          class="bid-share__account"
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

        <form
          phx-change="share_message_changed"
          phx-submit="share_message_changed"
          phx-target={@target}
        >
          <label for={"#{@id}-message"}>Your post</label>
          <textarea id={"#{@id}-message"} name="message" rows="3" phx-debounce="300">{@message}</textarea>
        </form>
        <a
          href={"https://x.com/intent/post?" <> URI.encode_query(%{text: @message})}
          target="_blank"
          rel="noopener noreferrer"
          class="rg-button rg-button--primary bid-primary"
        >
          <span class="rg-button__label">Open X to share</span>
        </a>
        <p class="bid-form__note">
          X opens with your post ready. Nothing is posted until you post it there.
        </p>
      </div>
    </div>
    """
  end

  @doc "The chain's explorer page for a transaction."
  def transaction_url(:base, hash), do: "https://basescan.org/tx/#{hash}"
  def transaction_url(:robinhood, hash), do: "https://robinhoodchain.blockscout.com/tx/#{hash}"

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
