defmodule AutolaunchWeb.RobinhoodStocksLaunchComponent do
  @moduledoc """
  The wallet step of a memestock pair launch on Robinhood: one review, then the
  one launch transaction. There is no launch fee.

  The review, the step and its outcomes follow `AutolaunchWeb.LaunchSteps`.
  Nothing is stored while a launch is on its way: the review lives on this
  page only. A confirmed launch is read back from the launchpad's own records
  for its auction page, and the list under the card is the launchpad's
  launches for the wallet that may act, or the signed-in one while Privy's
  active wallet is not one of the account's.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Robinhood.{Lab, StocksLaunchActions}
  alias AutolaunchWeb.{LaunchSteps, OnchainSteps, Paths}

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    robinhood_unavailable: "Robinhood launches are not open on this site.",
    launches_paused: "New launches are paused right now.",
    stock_not_admitted: "This stock is not open for launches right now. Choose another.",
    stock_invalid: "Choose a stock for this launch.",
    launch_metadata_incomplete: "This draft is missing something the launch needs.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket),
    do: {:ok, socket |> LaunchSteps.init() |> assign(launches: [], listed_for: nil)}

  # The review on the page, checked against the chain again once it is ten
  # minutes old (`AutolaunchWeb.LaunchSteps.rechecked/4`).
  @impl true
  def update(%{refresh_review: review_id}, socket),
    do: {:ok, LaunchSteps.refreshed(socket, review_id, current(socket), &prepare(socket, &1))}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> OnchainSteps.adopt()
     |> LaunchSteps.followed()
     |> listed()}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, steps: LaunchSteps.steps(assigns))

    ~H"""
    <section
      id={@id}
      class="launch-wallet"
      data-agent-tools="autolaunch_launch"
      phx-hook="OnchainSteps"
    >
      <LaunchSteps.launched_panel
        id={"#{@id}-launched"}
        launched={@launched}
        chain={explorer_chain()}
        target={@myself}
      />
      <p class="launch-wallet-notice" role="status" hidden={!@notice}>{@notice}</p>

      <div class="launch-wallet-open" hidden={!!@review or !!@launched}>
        <p class="launch-wallet-hint">
          Your wallet confirms the launch. You see every value before anything is sent.
        </p>
        <p class="launch-wallet-from" hidden={!@signer}>
          Launching from <code>{RegentFormat.short_address(@signer)}</code>
        </p>
        <p class="onchain-note" role="status" hidden={!@mismatch}>{@mismatch}</p>
        <Regent.Primitives.button
          class="launch-wallet-primary"
          type="button"
          phx-click="review_launch"
          phx-target={@myself}
        >
          Review launch
        </Regent.Primitives.button>
      </div>

      <%!-- The review stays in the page and is only hidden, so its wallet
           button is never replaced while a person presses it. --%>
      <section
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label="Launch review"
        hidden={!@review}
      >
        <%= if @review do %>
          <h4>Review this launch</h4>
          <dl>
            <div>
              <dt>Token</dt>
              <dd>{@prepared.facts["name"]} · {@prepared.facts["symbol"]}</dd>
            </div>
            <LaunchSteps.token_rows facts={@prepared.facts} />
            <div>
              <dt>Auction currency</dt>
              <dd>
                {@prepared.facts["stock_symbol"]}
                <span class="launch-wallet-mono">{@prepared.facts["stock"]}</span>
              </dd>
            </div>
            <div :for={[label, value] <- @prepared.review}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
            <div>
              <dt>Wallet</dt>
              <dd class="launch-wallet-mono">{RegentFormat.short_address(@review.signer)}</dd>
            </div>
            <div>
              <dt>Network</dt>
              <dd>{@review.chain.name} · chain {@review.chain.chain_id}</dd>
            </div>
            <div>
              <dt>Transactions</dt>
              <dd>One transaction</dd>
            </div>
          </dl>

          <p class="launch-wallet-risk">{@prepared.facts["risk"]}</p>

          <Regent.Primitives.disclosure
            id={"#{@id}-terms"}
            summary="Fixed terms"
            class="launch-wallet-details"
          >
            <dl>
              <div :for={[label, value] <- @prepared.facts["terms"]}>
                <dt>{label}</dt>
                <dd>{value}</dd>
              </div>
            </dl>
          </Regent.Primitives.disclosure>

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
        <% end %>

        <LaunchSteps.progress
          id={"#{@id}-progress"}
          steps={@steps}
          review={@review}
          chain={explorer_chain()}
          mismatch={@mismatch}
          press_note={@press_note}
          target={@myself}
        />
      </section>

      <section :if={@launches != []} class="launch-wallet-settled" aria-label="Your launches">
        <h4>Your Robinhood launches</h4>
        <ul role="list">
          <li :for={launch <- @launches}>
            Launch #{launch["launch_id"]} · {lifecycle(launch["lifecycle"])} ·
            <.link :if={launch["page"]} navigate={launch["page"]}>
              Auction <span class="launch-wallet-mono">{launch["auction"]}</span>
            </.link>
            <span :if={!launch["page"]}>
              Auction <span class="launch-wallet-mono">{launch["auction"]}</span>
            </span>
          </li>
        </ul>
      </section>
    </section>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, socket |> LaunchSteps.activated(params) |> listed()}

  def handle_event("review_launch", _params, socket),
    do: {:noreply, LaunchSteps.review(socket, &prepare(socket, &1))}

  def handle_event("agent_press", %{"tool" => "autolaunch_launch"}, socket) do
    {reply, socket} = LaunchSteps.agent_press(socket, &prepare(socket, &1))
    {:reply, reply, socket}
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket),
    do: {:noreply, LaunchSteps.failed(socket, params, :robinhood_launch)}

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
         &confirmed/2,
         &LaunchSteps.reverted(&1, &2, current(socket), fn signer -> prepare(socket, signer) end)
       )}

  # Each answer also reads the wallet's launches under the card again.
  def handle_async({:launch_page, hash}, answer, socket),
    do:
      {:noreply,
       socket
       |> LaunchSteps.found(hash, answer, &launch_page/2)
       |> assign(listed_for: nil)
       |> listed()}

  def handle_async(:launches, {:ok, {wallet, {:ok, %{launches: launches}}}}, socket) do
    if wallet == shown_wallet(socket.assigns),
      do: {:noreply, assign(socket, launches: with_pages(launches))},
      else: {:noreply, socket}
  end

  def handle_async(:launches, _unread, socket), do: {:noreply, socket}

  defp prepare(socket, signer) do
    case StocksLaunchActions.prepare(socket.assigns.draft.id, signer, opts(socket)) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, Map.get(@copy, refusal(error), @generic)}
    end
  end

  defp confirmed(socket, entry),
    do: LaunchSteps.launched(socket, entry, :memestake, &launch_page/2)

  # A confirmed launch is read back from the launchpad against the review it
  # was sent from; its page follows once the site lists its auction.
  defp launch_page(prepared, hash) do
    with {:ok, %{outcome: :confirmed, result: result}} <-
           StocksLaunchActions.confirmed(prepared, hash),
         page when is_binary(page) <- Paths.robinhood_auction_page(result["auction"]) do
      {:ok, page}
    else
      _not_yet -> :not_yet
    end
  end

  # A test network has no explorer.
  defp explorer_chain, do: if(Lab.test_chain?(), do: nil, else: :robinhood)

  # The launchpad's launches for the wallet shown, read in the background
  # whenever that wallet changes or a launch is confirmed.
  defp listed(socket) do
    wallet = shown_wallet(socket.assigns)

    if is_nil(wallet) or wallet == socket.assigns.listed_for do
      socket
    else
      opts = opts(socket)

      socket
      |> assign(listed_for: wallet)
      |> start_async(:launches, fn -> {wallet, StocksLaunchActions.launches(wallet, opts)} end)
    end
  end

  defp shown_wallet(%{linked: linked, signed_in: signed_in, active: active}),
    do: OnchainSteps.shown_wallet(linked, signed_in, active)

  # Each launch links to its auction's page once the site lists the auction.
  defp with_pages(launches),
    do: Enum.map(launches, &Map.put(&1, "page", Paths.robinhood_auction_page(&1["auction"])))

  defp current(_socket), do: &StocksLaunchActions.current/1

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp lifecycle("active"), do: "Active"
  defp lifecycle("graduated"), do: "Graduated"
  defp lifecycle("failed"), do: "Minimum raise not reached"
  defp lifecycle("none"), do: "Not started"

  defp exact_values(facts, review) do
    [
      {"Launchpad", facts["launchpad"]},
      {"Stock route", facts["route"]},
      {"Stock decimals", facts["stock_decimals"]},
      {"Minimum raise (stock base units)", facts["required_stock_raised"]},
      {"Starting price (Q96)", facts["floor_price_q96"]},
      {"Bid tick spacing (Q96)", facts["tick_spacing_q96"]},
      {"Bidding opens (blocks after creation)", facts["start_lead_blocks"]},
      {"Auction length (blocks)", facts["auction_duration_blocks"]},
      {"Reviewed block", "#{facts["block_number"]} · #{facts["block_hash"]}"},
      {"Calldata digest", LaunchSteps.digest(review)}
    ]
  end

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
