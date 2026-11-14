defmodule AutolaunchWeb.NearFundingComponent do
  @moduledoc """
  Fund with NEAR, beside a USDC bid the wallet cannot cover yet.

  The bid panel hands over `short`, the USDC its wallet lacks for the bid as
  Base reads it now (in USDC base units, or nil while it is not short or not
  read). The panel quotes exactly that shortfall, and a press records a funding
  whose USDC lands in the wallet the server names; nothing typed here chooses
  it. The person sends NEAR from their own wallet to the deposit address
  shown. The site only quotes and reads status: it builds no NEAR transaction
  and holds nothing.

  Each change the status job broadcasts reaches the panel through a small
  listener linked to the page (`send_update/3`), so no page has to forward
  it. Once the USDC arrives, the bid panel `bid_id` reads Base again and builds
  its own steps from the auction as it is now; the funding and the bid stay
  separate records.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Funding, LabBidChainClient}
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.OnchainSteps
  alias Phoenix.LiveView.AsyncResult
  alias RegentChain.Address

  @usdc_decimals 6
  @open [:pending_deposit, :processing]

  @status %{
    pending_deposit: "Waiting for NEAR",
    processing: "Converting",
    success: "Arrived",
    refunded: "Refunded",
    failed: "Failed"
  }

  @copy %{
    invalid_refund_account: "Enter your NEAR account, like you.near.",
    near_unavailable: "NEAR funding can't be reached just now. Try again in a moment.",
    wallet_required: "Open one of your account's wallets in your wallet app first.",
    wrong_signer: "Your wallet changed, so nothing was started. Try again.",
    unknown_auction: "This auction can't be funded here.",
    invalid_amount: "There is nothing to fund for this bid."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(fn socket, _account -> socket end)
     |> assign(
       quoted_for: nil,
       quote: AsyncResult.ok(nil),
       funding: nil,
       following: nil,
       refund_to: "",
       notice: nil,
       eth: AsyncResult.ok(nil)
     )}
  end

  # A change the status job broadcast, or a status read now.
  @impl true
  def update(%{funding: funding}, socket), do: {:ok, funded(socket, funding)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> requoted()
     |> resumed()}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        open?: open?(assigns.funding),
        receipt?: receipt?(assigns.funding),
        elsewhere?: elsewhere?(recipient(assigns.quote, nil), assigns.wallet)
      )

    ~H"""
    <section
      id={@id}
      class="bid-box near-fund"
      aria-label="Fund with NEAR"
      hidden={!(@short || @funding)}
    >
      <h3 class="near-fund__title">NEAR funding</h3>

      <div :if={@short} class="near-fund__rows">
        <div class="bid-box__sub">
          <span>Needed</span>
          <span><span class="figure__value">{usdc(@short)}</span> <span class="ticker">USDC</span></span>
        </div>
        <div :if={recipient(@quote, @funding)} class="bid-box__sub">
          <span>To</span>
          <Regent.Primitives.address
            id={"#{@id}-recipient"}
            address={recipient(@quote, @funding)}
            variant="compact"
          />
        </div>
      </div>

      <p :if={@short && @elsewhere?} class="bid-box__note">
        NEAR funding goes to your sign-in wallet. Open it in your wallet app to fund this bid.
      </p>

      <form
        :if={@short && !@open? && !@elsewhere?}
        id={"#{@id}-form"}
        class="near-fund__form"
        phx-submit="fund"
        phx-target={@myself}
      >
        <label class="bid-box__label" for={"#{@id}-refund"}>NEAR account</label>
        <input
          id={"#{@id}-refund"}
          class="near-fund__input"
          type="text"
          name="refund_to"
          value={@refund_to}
          placeholder="you.near"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
        />
        <p class="bid-box__note" role="status">
          <%= cond do %>
            <% @quote.loading -> %>
              Getting a price…
            <% @quote.failed -> %>
              {copy(@quote.failed)}
            <% @quote.ok? && @quote.result -> %>
              About {@quote.result.near_amount} NEAR, around {@quote.result.time_estimate_s} seconds
            <% true -> %>
          <% end %>
        </p>
        <Regent.Primitives.button type="submit" phx-disable-with="Starting…">
          Fund with NEAR
        </Regent.Primitives.button>
      </form>

      <p class="bid-notice" role="alert" hidden={!@notice}>{@notice}</p>

      <div :if={@funding} class="near-fund__rows">
        <%= if @open? do %>
          <div class="bid-box__sub">
            <span>Send</span>
            <span><span class="figure__value">{@funding.near_amount}</span>
            <span class="ticker">NEAR</span></span>
          </div>
          <div class="near-fund__deposit">
            <span class="bid-box__label">Deposit address</span>
            <%!-- A NEAR address, so not the `0x` address primitive: the whole
                 text to check, with the shared copy icon. --%>
            <span class="near-fund__address">
              <span id={"#{@id}-deposit"}>{@funding.deposit_address}</span>
              <Regent.Primitives.copy_icon
                id={"#{@id}-deposit-copy"}
                text={@funding.deposit_address}
                label="Copy deposit address"
              />
            </span>
          </div>
          <p class="bid-box__note">
            Send from your own NEAR wallet before {deadline(@funding.deadline)}.
          </p>
        <% end %>
        <div class="bid-box__sub">
          <span>Status</span>
          <span class="near-fund__status" role="status" aria-live="polite">
            {status(@funding.state)}
            <button
              :if={@open?}
              type="button"
              class="near-fund__check"
              phx-click="check"
              phx-target={@myself}
            >
              Check status
            </button>
          </span>
        </div>
        <dl :if={@receipt?} class="bid-form__summary near-fund__receipt" aria-label="Receipt">
          <div>
            <dt>NEAR sent</dt><dd>{@funding.near_amount} <span class="ticker">NEAR</span></dd>
          </div>
          <div :if={@funding.state == :success}>
            <dt>USDC received</dt><dd>
              {usdc(@funding.usdc_amount)} <span class="ticker">USDC</span>
            </dd>
          </div>
          <div :if={@funding.origin_tx}>
            <dt>NEAR</dt>
            <dd>
              <a href={near_tx(@funding.origin_tx)} target="_blank" rel="noopener noreferrer">
                View on NEAR ↗
              </a>
            </dd>
          </div>
          <div :if={@funding.destination_tx}>
            <dt>Base</dt>
            <dd>
              <a href={base_tx(@funding.destination_tx)} target="_blank" rel="noopener noreferrer">
                View on Basescan ↗
              </a>
            </dd>
          </div>
          <div>
            <dt>Verification</dt><dd>Not checked</dd>
          </div>
        </dl>
        <p :if={@eth.ok? && @eth.result == 0} class="bid-notice" role="status" data-near-fee>
          This wallet has no ETH on Base for the network fee.
        </p>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("fund", %{"refund_to" => refund_to}, %{assigns: %{short: short}} = socket)
      when is_binary(refund_to) and is_integer(short) do
    refund_to = refund_to |> String.slice(0, 64) |> String.trim()
    socket = assign(socket, refund_to: refund_to, notice: nil)

    case Funding.start_near_funding(socket.assigns.auction_id, short, refund_to,
           actor: OnchainSteps.actor(socket)
         ) do
      {:ok, funding} -> {:noreply, funded(socket, funding)}
      {:error, error} -> {:noreply, assign(socket, notice: copy(error))}
    end
  end

  def handle_event("fund", _params, socket), do: {:noreply, socket}

  def handle_event("check", _params, %{assigns: %{funding: %{} = funding}} = socket) do
    case Funding.refresh_near_funding(funding, actor: OnchainSteps.actor(socket)) do
      {:ok, funding} -> {:noreply, funded(socket, funding)}
      {:error, error} -> {:noreply, assign(socket, notice: copy(error))}
    end
  end

  def handle_event("check", _params, socket), do: {:noreply, socket}

  # The newest funding still open for this auction, after a reload.
  @impl true
  def handle_async(:resume, {:ok, {:ok, fundings}}, %{assigns: %{funding: nil}} = socket),
    do: {:noreply, fundings |> Enum.find(&open?/1) |> then(&funded(socket, &1))}

  def handle_async(:resume, _result, socket), do: {:noreply, socket}

  # A funding: shown, followed while it is open, and once its USDC arrives the
  # bid panel reads Base again and the wallet's ETH for the fee is checked.
  defp funded(socket, nil), do: socket

  defp funded(socket, funding) do
    arrived? =
      funding.state == :success and
        not match?(%{state: :success}, socket.assigns.funding)

    socket
    |> assign(funding: funding, notice: nil)
    |> followed(funding)
    |> arrived(arrived?)
  end

  defp arrived(socket, false), do: socket

  defp arrived(%{assigns: %{bid_id: bid_id, funding: funding}} = socket, true) do
    send_update(AutolaunchWeb.BidComponent, id: bid_id, near_funded: true)
    recipient = funding.recipient

    assign_async(socket, :eth, fn ->
      with {:ok, wei} <- LabBidChainClient.eth_balance(recipient), do: {:ok, %{eth: wei}}
    end)
  end

  # One listener per open funding, linked to the page so it ends with it; it
  # hands each broadcast change to this panel and stops once the funding is
  # finished.
  defp followed(%{assigns: %{following: id}} = socket, %{id: id}), do: socket

  defp followed(socket, %{id: funding_id} = funding) do
    if open?(funding) and connected?(socket) do
      page = self()
      panel = socket.assigns.id

      {:ok, _listener} =
        Task.start_link(fn ->
          Phoenix.PubSub.subscribe(Autolaunch.PubSub, "near_funding:#{funding_id}")
          listen(page, panel)
        end)

      assign(socket, following: funding_id)
    else
      socket
    end
  end

  defp listen(page, panel) do
    receive do
      {:near_funding, funding} ->
        send_update(page, __MODULE__, id: panel, funding: funding)
        if open?(funding), do: listen(page, panel)
    end
  end

  # The price for exactly the shortfall, asked again whenever it changes.
  defp requoted(%{assigns: %{short: short, quoted_for: short}} = socket), do: socket

  defp requoted(%{assigns: %{short: short}} = socket) when is_integer(short) do
    auction_id = socket.assigns.auction_id
    actor = OnchainSteps.actor(socket)

    socket
    |> assign(quoted_for: short)
    |> assign_async(:quote, fn ->
      with {:ok, quote} <- Funding.quote_near_funding(auction_id, short, actor: actor),
           do: {:ok, %{quote: quote}}
    end)
  end

  defp requoted(socket), do: assign(socket, quoted_for: nil, quote: AsyncResult.ok(nil))

  defp resumed(%{assigns: %{resumed?: true}} = socket), do: socket

  defp resumed(socket) do
    auction_id = socket.assigns.auction_id
    actor = OnchainSteps.actor(socket)

    socket
    |> assign(resumed?: true)
    |> start_async(:resume, fn -> Funding.near_fundings_for(auction_id, actor: actor) end)
  end

  defp open?(%{state: state}), do: state in @open
  defp open?(nil), do: false

  defp receipt?(%{state: state}), do: state not in @open
  defp receipt?(nil), do: false

  defp recipient(_quote, %{recipient: recipient}), do: recipient
  defp recipient(%AsyncResult{ok?: true, result: %{recipient: recipient}}, nil), do: recipient
  defp recipient(_quote, nil), do: nil

  # The USDC lands in the account's sign-in wallet; a bid from another of its
  # wallets is not funded by it.
  defp elsewhere?(recipient, wallet) when is_binary(recipient),
    do: not Address.equal?(recipient, wallet)

  defp elsewhere?(nil, _wallet), do: false

  defp status(state), do: Map.fetch!(@status, state)

  defp usdc(amount), do: Rpc.format_units(amount, @usdc_decimals)

  defp deadline(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b, %H:%M UTC")

  defp near_tx(hash), do: "https://nearblocks.io/txns/" <> hash
  defp base_tx(hash), do: "https://basescan.org/tx/" <> hash

  defp copy({:error, error}), do: copy(error)
  defp copy({:exit, _reason}), do: @generic
  defp copy(error), do: Map.get(@copy, Funding.reason(error), @generic)
end
