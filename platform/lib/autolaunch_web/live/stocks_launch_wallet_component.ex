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

  alias Autolaunch.Actors.Human
  alias Autolaunch.Lab
  alias Autolaunch.Stocks.{Amounts, LaunchActions}
  alias AutolaunchWeb.{LaunchSteps, OnchainSteps}

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
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
  def mount(socket), do: {:ok, LaunchSteps.init(socket)}

  # The review on the page, checked against the chain again once it is ten
  # minutes old (`AutolaunchWeb.LaunchSteps.rechecked/4`).
  @impl true
  def update(%{refresh_review: review_id}, socket),
    do: {:ok, LaunchSteps.refreshed(socket, review_id, current(socket), &prepare(socket, &1))}

  def update(assigns, socket),
    do: {:ok, socket |> assign(assigns) |> OnchainSteps.adopt() |> LaunchSteps.followed()}

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
            <div>
              <dt>Minimum raise</dt>
              <dd>
                {Amounts.grouped(@prepared.facts["minimum_raise_units"])} {@prepared.facts[
                  "stock_symbol"
                ]}. If bids fall short, each bidder takes back their whole bid.
              </dd>
            </div>
            <div>
              <dt>Bidding opens</dt>
              <dd>
                {LaunchActions.schedule_copy(LaunchActions.start_lead_blocks())} after the launch is created
              </dd>
            </div>
            <div>
              <dt>Auction length</dt>
              <dd>{LaunchActions.schedule_copy(LaunchActions.auction_duration_blocks())}</dd>
            </div>
            <div>
              <dt>Starting price</dt>
              <dd>
                {Amounts.compact_decimal(@prepared.facts["floor_price_executable"])} {@prepared.facts[
                  "stock_symbol"
                ]} per token, the lowest the auction accepts
              </dd>
            </div>
            <div>
              <dt>Launch fee</dt>
              <dd>None</dd>
            </div>
            <div>
              <dt>Wallet</dt>
              <dd class="launch-wallet-mono">{RegentFormat.short_address(@review.signer)}</dd>
            </div>
            <div>
              <dt>Network</dt>
              <dd>{@review.chain.name}</dd>
            </div>
            <div>
              <dt>Transactions</dt>
              <dd>One transaction</dd>
            </div>
          </dl>

          <p class="launch-wallet-risk">{@prepared.facts["risk"]}</p>

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
    </section>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, LaunchSteps.activated(socket, params)}

  def handle_event("review_launch", _params, socket),
    do: {:noreply, LaunchSteps.review(socket, &prepare(socket, &1))}

  def handle_event("agent_press", %{"tool" => "autolaunch_launch"}, socket) do
    {reply, socket} = LaunchSteps.agent_press(socket, &prepare(socket, &1))
    {:reply, reply, socket}
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket),
    do: {:noreply, LaunchSteps.failed(socket, params, :stocks_launch)}

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  # The saved review is withdrawn too, so nothing is later listed from it.
  def handle_event("cancel_review", _params, %{assigns: %{prepared: prepared}} = socket) do
    if prepared, do: LaunchActions.cancel(prepared.action_id, opts(socket))
    {:noreply, LaunchSteps.withdrawn(socket)}
  end

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
         &LaunchSteps.launched(&1, &2, :memestake, LaunchSteps.base_page(:stocks_launch)),
         &LaunchSteps.reverted(&1, &2, current(socket), fn signer -> prepare(socket, signer) end)
       )}

  def handle_async({:launch_page, hash}, answer, socket),
    do: {:noreply, LaunchSteps.found(socket, hash, answer, LaunchSteps.base_page(:stocks_launch))}

  defp prepare(socket, signer) do
    case LaunchActions.prepare(socket.assigns.draft.id, signer, opts(socket)) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, copy(refusal(error))}
    end
  end

  defp current(_socket), do: &LaunchActions.current/1

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

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

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
