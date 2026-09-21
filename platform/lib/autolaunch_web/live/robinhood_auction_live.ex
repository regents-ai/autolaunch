defmodule AutolaunchWeb.RobinhoodAuctionLive do
  @moduledoc """
  One Robinhood memestock auction, named by its address. The chain is the only
  record of these auctions, so the page holds no listing of its own: it names
  the auction, hands the signed-in wallet the bid step, and once the launch
  has graduated, the staking card for its token holders.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.{Lab, Pool}

  @not_graduated [:not_graduated, :unknown_auction, :invalid_auction]

  def mount(_params, _session, socket), do: {:ok, assign(socket, :open?, Lab.configured?())}

  def handle_params(%{"auction" => auction}, _uri, socket) do
    case Address.normalize(auction) do
      {:ok, address} -> {:noreply, socket |> assign(:auction, address) |> load_pool(true)}
      :error -> {:noreply, assign(socket, auction: nil, pool: %Phoenix.LiveView.AsyncResult{})}
    end
  end

  def handle_event("reload_pool", _params, socket), do: {:noreply, load_pool(socket, false)}

  # The staking card confirmed something that moved the pool's figures, so the
  # pool is read again. The previous figures stay on the page while the lab
  # answers, so the card that asked keeps its wallet, position and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load_pool(socket, false)}

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
      <.live_component
        :if={@pool.ok?}
        module={AutolaunchWeb.StakeComponent}
        id={"robinhood-stake-#{@auction}"}
        launch={%{chain: :robinhood, auction: @auction}}
        pool={@pool.result}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <div :if={unreadable?(@pool)} role="alert" class="autolaunch-empty">
        <p>The staking figures could not be read just now.</p>
        <Regent.Primitives.button phx-click="reload_pool" variant="secondary">
          Read again
        </Regent.Primitives.button>
      </div>
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

  # The pool is its own read of the lab: a launch that has not graduated has no
  # pool and shows nothing. A fresh page starts from nothing; a re-read keeps
  # the last figures until the new ones arrive.
  defp load_pool(%{assigns: %{open?: false}} = socket, _reset?),
    do: assign(socket, :pool, %Phoenix.LiveView.AsyncResult{})

  defp load_pool(socket, reset?) do
    auction = socket.assigns.auction

    assign_async(
      socket,
      :pool,
      fn ->
        with {:ok, facts} <- Pool.read(auction), do: {:ok, %{pool: facts}}
      end,
      reset: reset?
    )
  end

  defp unreadable?(%{failed: nil}), do: false
  defp unreadable?(%{failed: {:error, reason}}) when reason in @not_graduated, do: false
  defp unreadable?(_failed), do: true
end
