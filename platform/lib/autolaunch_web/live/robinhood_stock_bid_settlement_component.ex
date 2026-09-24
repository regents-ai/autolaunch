defmodule AutolaunchWeb.RobinhoodStockBidSettlementComponent do
  @moduledoc """
  One bid on a Robinhood memestock auction and what can come back from it: the
  unspent stock the bid did not use, and the launch tokens it won.

  The auction's own answer decides what is on screen: one review, then at most
  two transactions (the return, then the claim), or the auction's reason
  nothing can be done yet. Nothing is stored: the review lives on this page
  only, the browser reports a hash and stops, and every outcome on screen is
  the server's own read of that hash. A confirmed step asks the bid panel to
  read the wallet's bids again.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Robinhood.{Lab, StockBidSettlementActions}
  alias AutolaunchWeb.{RobinhoodStockBidComponent, UsdValue}

  @copy %{
    authentication_required: "Sign in to settle this bid.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    not_your_bid:
      "This bid was placed from a different wallet. Sign in with that wallet to settle it.",
    bid_not_found: "The auction has no record of this bid.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "Robinhood changed while this was prepared. Try again.",
    robinhood_unavailable: "Robinhood auctions are not open on this site.",
    invalid_auction: "This is not an auction address.",
    stock_not_listed: "This auction's stock is not one this site lists.",
    auction_not_started: "Bidding has not started on this auction.",
    auction_not_ended: "This bid stays in the auction until bidding ends.",
    already_exited: "This bid has already been returned.",
    claim_not_open: "Tokens cannot be claimed yet.",
    nothing_to_claim: "This bid has no tokens to claim.",
    bid_not_exited: "Return this bid before claiming its tokens.",
    failed_bid_returned:
      "Your bid was returned in full. This launch did not raise enough, and there are no tokens to claim.",
    bid_needs_partial_exit_hints_unavailable:
      "This bid was only partly filled and the auction's records for it could not be traced. Try again in a moment.",
    settlement_reverted: "The auction refused this right now.",
    envelope_invalid: "This review is out of date. Review it again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @steps %{"exit" => :exit, "claim" => :claim}

  @impl true
  def update(assigns, socket) do
    identity =
      {assigns.auction, assigns.bid["bid_id"], assigns.wallet, assigns.current_human_id,
       assigns.session_lease}

    socket =
      if socket.assigns[:settlement_identity] in [nil, identity],
        do: socket,
        else: cleared(socket)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:settlement_identity, identity)
     |> assign(:returned?, returned?(assigns.bid, assigns.graduated?))
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:review, fn -> nil end)
     |> assign_new(:stake_path, fn -> nil end)
     |> assign_new(:token_symbol, fn -> "tokens" end)
     |> assign_new(:after_claim, fn -> :wallet end)
     |> assign_new(:sent, fn -> %{} end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="bid-settlement-row" phx-hook="AutolaunchReviewedSteps" phx-target={@myself}>
      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <p :if={@returned?} class="launch-wallet-settled" role="status">
        {returned_copy()}
      </p>

      <div :if={!@review && !@returned?} class="launch-wallet-controls">
        <Regent.Primitives.button
          type="button"
          phx-click="review_settlement"
          phx-target={@myself}
          variant="secondary"
        >
          {if @graduated?,
            do: "Review return and claim #{@token_symbol} to wallet",
            else: "Review withdrawal"}
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@stake_path && @bid["tokens_filled_now"] not in [nil, "0"]}
          type="button"
          phx-click="review_settlement"
          phx-value-after="stake"
          phx-target={@myself}
        >
          Memestake {@token_symbol}
        </Regent.Primitives.button>
      </div>
      <.link
        :if={@stake_path && @bid["exited_block"] != "0" && @bid["tokens_filled_now"] == "0"}
        navigate={@stake_path}
        class="rg-button rg-button--secondary"
      >Open staking</.link>

      <section
        :if={@review}
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label={"Settle bid ##{@bid["bid_id"]}"}
      >
        <h4>Settle bid #{@bid["bid_id"]}</h4>
        <p :if={@after_claim == :stake}>
          First claim to your wallet, then continue to Memestake. Your wallet confirms each step. Tokens are not locked.
        </p>
        <p :if={!@review.envelope["arguments"]["graduated"]}>
          The auction for {@token_symbol} did not meet its minimum raise. Your returned bid is {@review.envelope[
            "arguments"
          ]["stock_refunded_units"]} {@review.envelope["arguments"]["stock_symbol"]}, sent to the receiving wallet below.
        </p>
        <dl>
          <div :for={row <- @review.review}>
            <dt>{row.label}</dt>
            <dd>
              {row.value}
              <UsdValue.usd :if={row.worth} amount={row.worth} rate={@usd_rate} per={row.per} />
            </dd>
          </div>
          <div>
            <dt>Receiving wallet</dt>
            <dd class="autolaunch-exact-value">{@review.envelope["expected_signer"]}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>
              {Lab.network_name(@review.envelope["chain_id"])} · chain {@review.envelope["chain_id"]}
            </dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>{step_count(@review.steps)}</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@review.envelope["risk_copy"]}</p>

        <ol class="launch-wallet-steps" role="list" aria-label="Settlement progress">
          <li :for={step <- @review.steps} data-step={step["step"]}>
            <span>{step_label(step["step"], @review)}</span>
            <span class="launch-wallet-step-state">{step_state(@sent[step["step"]])}</span>
            <span
              :if={@sent[step["step"]]}
              class="launch-wallet-mono"
              data-local-transaction-hash
            >
              {short_hash(@sent[step["step"]].hash)}
            </span>
          </li>
        </ol>

        <p :if={done?(@review.steps, @sent)} class="launch-wallet-settled" role="status">
          {done_copy(@review.steps)}
          <span :if={Lab.test_chain?(@review.envelope["chain_id"])}>Test assets have no real value.</span>
        </p>

        <Regent.Primitives.disclosure
          id={"#{@id}-exact-values"}
          summary="Exact values"
          class="launch-wallet-details"
        >
          <dl>
            <div :for={{label, value} <- exact_values(@review)}>
              <dt>{label}</dt>
              <dd class="launch-wallet-mono">{value}</dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>

        <div class="launch-wallet-controls">
          <Regent.Primitives.button
            :for={step <- @review.steps}
            :if={!done?(@review.steps, @sent)}
            type="button"
            data-reviewed-step={step["step"]}
            variant={
              if step["step"] == next_step(@review.steps, @sent), do: "primary", else: "secondary"
            }
          >
            {step_label(step["step"], @review)}
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :for={{name, %{outcome: :pending}} <- @sent}
            type="button"
            phx-click="check_step"
            phx-value-step={name}
            phx-target={@myself}
            variant="secondary"
          >
            Check again
          </Regent.Primitives.button>
          <Regent.Primitives.button
            type="button"
            phx-click="clear_review"
            phx-target={@myself}
            variant="secondary"
          >
            {if done?(@review.steps, @sent), do: "Done", else: "Start over"}
          </Regent.Primitives.button>
        </div>
      </section>
    </div>
    """
  end

  @impl true
  def handle_event("review_settlement", params, socket) do
    socket =
      assign(socket, :after_claim, if(params["after"] == "stake", do: :stake, else: :wallet))

    request = %{auction: socket.assigns.auction, bid_id: socket.assigns.bid["bid_id"]}

    case StockBidSettlementActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply, socket |> assign(review: review, sent: %{}, notice: nil) |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: notice(:info, refusal(error)))}
    end
  end

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, checked(socket, name, hash)}

  def handle_event("check_step", %{"step" => name}, socket) do
    case socket.assigns.sent[name] do
      %{hash: hash} -> {:noreply, checked(socket, name, hash)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

  def handle_event("clear_review", _params, socket), do: {:noreply, cleared(socket)}

  # The wallet itself is the bid panel's; this row only follows it.
  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    case StockBidSettlementActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket)) do
      {:ok, %{outcome: outcome}} ->
        socket
        |> assign(
          sent: Map.put(socket.assigns.sent, name, %{hash: hash, outcome: outcome}),
          notice: outcome_notice(name, outcome)
        )
        |> listed(outcome)

      {:error, error} ->
        assign(socket, notice: notice(:error, refusal(error)))
    end
  end

  defp checked(socket, _name, _hash), do: socket

  # A confirmed step changed the bid's record; the bid panel reads it again.
  defp listed(socket, :confirmed) do
    send_update(RobinhoodStockBidComponent, id: socket.assigns.parent_id, refresh_bids: true)

    if socket.assigns.after_claim == :stake && is_binary(socket.assigns.stake_path) &&
         match?(%{outcome: :confirmed}, socket.assigns.sent["claim"]) do
      amount = socket.assigns.review.envelope["arguments"]["tokens_claimed_units"] || ""

      path =
        String.replace_suffix(
          socket.assigns.stake_path,
          "#stake",
          "?" <> URI.encode_query(%{stake: amount}) <> "#stake"
        )

      socket |> assign(after_claim: :wallet) |> push_navigate(to: path)
    else
      socket
    end
  end

  defp listed(socket, _outcome), do: socket

  defp published(%{assigns: %{review: %{envelope: envelope, steps: steps}}} = socket) do
    push_event(socket, "reviewed-steps:review", %{
      component_id: socket.assigns.id,
      signer: envelope["expected_signer"],
      chain_id: envelope["chain_id"],
      lab: envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: envelope["arguments"]["block_number"],
        block_hash: envelope["arguments"]["block_hash"]
      },
      steps: Enum.map(steps, &Map.take(&1, ["step", "to", "data"]))
    })
  end

  # An exited bid with nothing filled on an auction that did not graduate has
  # had its whole stake returned; the auction offers it nothing further. On a
  # graduated auction the same record means the tokens were claimed.
  defp returned?(%{"exited_block" => exited, "tokens_filled_now" => "0"}, false),
    do: exited != "0"

  defp returned?(_bid, _graduated?), do: false

  defp returned_copy, do: @copy.failed_bid_returned

  defp cleared(socket) do
    socket
    |> assign(review: nil, sent: %{}, notice: nil, after_claim: :wallet)
    |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp done?(steps, sent),
    do: Enum.all?(steps, &match?(%{outcome: :confirmed}, sent[&1["step"]]))

  defp next_step(steps, sent) do
    Enum.find_value(steps, fn %{"step" => name} ->
      if match?(%{outcome: :confirmed}, sent[name]), do: nil, else: name
    end)
  end

  defp done_copy(steps) do
    case Enum.map(steps, & &1["step"]) do
      ["exit"] ->
        "Your unspent stock was returned and the auction's record of it was verified."

      ["claim"] ->
        "Your tokens were claimed and the auction's record of it was verified."

      _both ->
        "Your unspent stock was returned, your tokens were claimed, and the auction's records were verified."
    end
  end

  defp exact_values(review) do
    arguments = review.envelope["arguments"]

    [
      {"Auction", arguments["auction"]},
      {"Bid id", arguments["onchain_bid_id"]},
      {"Stock", arguments["stock"]},
      {"Bid amount (base units)", arguments["bid_amount_atomic"]},
      {"Max price (Q96)", arguments["max_price_q96"]},
      {"Final price (Q96)", arguments["final_clearing_price_q96"]},
      {"Reviewed block", "#{arguments["block_number"]} · #{arguments["block_hash"]}"},
      {"Calldata digest", review.envelope["metadata"]["calldata_sha256"]}
    ]
  end

  defp step_count([_one]), do: "One transaction"
  defp step_count([_one, _two]), do: "Two transactions"

  defp step_label("exit", %{envelope: %{"arguments" => arguments}}),
    do: "Withdraw #{arguments["stock_refunded_units"]} #{arguments["stock_symbol"]}"

  defp step_label("claim", _review), do: "Claim tokens to wallet"

  defp step_state(nil), do: "Ready"
  defp step_state(%{outcome: :pending}), do: "Sent"
  defp step_state(%{outcome: :confirmed}), do: "Verified"
  defp step_state(%{outcome: :reverted}), do: "Reverted"
  defp step_state(%{outcome: :unverified}), do: "Unresolved"

  defp outcome_notice(_name, :pending),
    do: %{tone: :info, message: "Sent. Waiting for Robinhood to include it."}

  defp outcome_notice(_name, :confirmed), do: nil

  defp outcome_notice("exit", :reverted),
    do: %{tone: :error, message: "That transaction reverted. Nothing was returned by it."}

  defp outcome_notice("claim", :reverted),
    do: %{tone: :error, message: "That transaction reverted. Nothing was claimed by it."}

  defp outcome_notice(_name, :unverified),
    do: %{tone: :error, message: "That transaction did not record the step you reviewed."}

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under the reviewed chain number. Check the network settings in your wallet, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
