defmodule AutolaunchWeb.StocksLaunchWalletComponent do
  @moduledoc """
  The wallet step of a Stocks launch on Base: one review, then the one launch
  transaction. There is no launch fee.

  The review, the step and its outcomes follow `AutolaunchWeb.LaunchSteps`.
  The review is saved (`Autolaunch.Stocks.LaunchOperation`) so the launch it
  carries out is listed for this account: as soon as this page sees it
  confirmed and Base answers for it, otherwise when discovery finds it.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Lab
  alias Autolaunch.Stocks.LaunchActions
  alias AutolaunchWeb.Components.StockIdentity
  alias AutolaunchWeb.{LaunchSteps, OnchainSteps, TokenDisplay}
  alias AutolaunchWeb.Live.Session

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    sign_in_unread: "That did not go through. Try again in a moment.",
    wrong_signer: "Your wallet changed during the press, so nothing was sent. Press again.",
    invalid_address: "Open one of your account's wallets in your wallet app, then press again.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    stocks_unavailable: "Stock launches are not open on this site.",
    launches_paused: "New launches are paused right now.",
    stock_not_admitted: "This stock token is not admitted for launches right now.",
    launch_metadata_incomplete: "This draft is missing something the launch needs.",
    stock_invalid: "Choose a stock token on the draft.",
    unsupported_stock: "Choose a stock token on the draft.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket),
    do: {:ok, socket |> Session.check_component_lease(&take_account/2) |> LaunchSteps.init()}

  # The review on the page, checked against the chain again once it is ten
  # minutes old (`AutolaunchWeb.LaunchSteps.refreshed/4`).
  @impl true
  def update(%{refresh_review: review_id}, socket),
    do: {:ok, LaunchSteps.refreshed(socket, review_id, current(socket), &prepare(socket, &1))}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> OnchainSteps.adopt()
     |> LaunchSteps.followed()
     |> LaunchSteps.relisted(socket.assigns.listings)}
  end

  # The account as it reads now, before each event and background result
  # (`Session.check_component_lease/2`): a change to its wallets moves the
  # card onto them.
  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &LaunchSteps.followed/1)

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="launch-wallet"
      phx-hook="OnchainSteps"
    >
      <LaunchSteps.launched_panel
        id={"#{@id}-launched"}
        launched={@launched}
        chain={explorer_chain()}
        target={@myself}
      />
      <p class="launch-wallet-notice" role="status" hidden={!@notice}>{@notice}</p>

      <LaunchSteps.review_button
        id={@id}
        hidden={!!@review or !!@launched}
        signer={@signer}
        mismatch={@mismatch}
        disabled={@launches_paused?}
        target={@myself}
      />

      <LaunchSteps.review_panel
        id={@id}
        review={@review}
        prepared={@prepared}
        presses={@presses}
        chain={explorer_chain()}
        mismatch={@mismatch}
        press_note={@press_note}
        target={@myself}
      >
        <:rows>
          <div>
            <dt>Auction currency</dt>
            <dd>
              {@prepared.facts["stock_symbol"]} · {StockIdentity.words(:base)}
              <Regent.Primitives.address
                id={"#{@id}-stock"}
                address={@prepared.facts["stock"]}
                variant="full"
                chain={LaunchSteps.address_chain(explorer_chain())}
              />
            </dd>
          </div>
          <div>
            <dt>Minimum raise</dt>
            <dd>
              {TokenDisplay.short(@prepared.facts["minimum_raise_units"])} {@prepared.facts[
                "stock_symbol"
              ]}. If bids fall short, each bidder takes back their whole bid.
            </dd>
          </div>
          <div>
            <dt>Bidding opens</dt>
            <dd>
              {LaunchActions.schedule_copy(:base, LaunchActions.schedule(:base).opens)} after the launch is created
            </dd>
          </div>
          <div>
            <dt>Auction length</dt>
            <dd>{LaunchActions.schedule_copy(:base, LaunchActions.schedule(:base).length)}</dd>
          </div>
          <div>
            <dt>Starting price</dt>
            <dd>
              {TokenDisplay.short(@prepared.facts["floor_price_executable"])} {@prepared.facts[
                "stock_symbol"
              ]} per token, the lowest the auction accepts
            </dd>
          </div>
          <div>
            <dt>Launch fee</dt>
            <dd>None</dd>
          </div>
        </:rows>
        <Regent.Primitives.disclosure
          id={"#{@id}-exact-values"}
          summary="Exact values"
          class="launch-wallet-details"
        >
          <dl>
            <div :for={{label, value} <- exact_values(@prepared.facts, @review)}>
              <dt>{label}</dt>
              <dd class="launch-wallet-mono">{value}</dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>
      </LaunchSteps.review_panel>
    </section>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, LaunchSteps.activated(socket, params)}

  def handle_event("review_launch", _params, socket),
    do: {:noreply, LaunchSteps.review(socket, &prepare(socket, &1))}

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket),
    do: {:noreply, OnchainSteps.failed(socket, params, :stocks_launch, nil)}

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("cancel_review", _params, socket),
    do: {:noreply, LaunchSteps.withdrawn(socket)}

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> assign(launched: nil) |> LaunchSteps.withdrawn()}

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do:
      {:noreply,
       OnchainSteps.checked(
         socket,
         hash,
         result,
         &LaunchSteps.launched(&1, &2, :memestock, LaunchSteps.base_page(:stocks_launch)),
         &LaunchSteps.reverted(&1, &2, current(socket), fn signer -> prepare(socket, signer) end)
       )}

  def handle_async({:launch_page, hash}, answer, socket),
    do: {:noreply, LaunchSteps.found(socket, hash, answer)}

  defp prepare(socket, signer) do
    case LaunchActions.prepare(socket.assigns.draft.id, signer, OnchainSteps.opts(socket)) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, copy(OnchainSteps.refusal(error))}
    end
  end

  defp current(_socket), do: &LaunchActions.current/1

  # A test network has no explorer.
  defp explorer_chain, do: if(Lab.test_chain?(), do: nil, else: :base)

  defp exact_values(facts, review) do
    [
      {"Launchpad", facts["launchpad"]},
      {"Stock token", facts["stock"]},
      {"Stock decimals", facts["stock_decimals"]},
      {"Minimum raise (stock base units)", facts["required_stock_raised"]},
      {"Starting price (every digit)",
       "#{facts["floor_price_executable"]} #{facts["stock_symbol"]} per token"},
      {"Starting price (Q96)", facts["floor_price_q96"]},
      {"Bid tick spacing (Q96)", facts["tick_spacing_q96"]},
      {"Bidding opens (blocks after creation)", facts["start_lead_blocks"]},
      {"Auction length (blocks)", facts["auction_duration_blocks"]},
      {"Reviewed block", "#{facts["block_number"]} · #{facts["block_hash"]}"},
      {"Calldata digest", LaunchSteps.digest(review)}
    ]
  end

  defp copy(:chain_unavailable) do
    if Lab.test_chain?(),
      do: "The Base fork could not be read just now. Check that it is still running.",
      else: Map.fetch!(@copy, :chain_unavailable)
  end

  defp copy(reason), do: Map.get(@copy, reason, @generic)
end
