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

  With `early`, the bid is an outbid one while bidding is still open. The
  auction is asked in the background whether it would return the unspent
  stock now, and again at most every half minute while it would not. Only
  once it would is the return reviewed and the button shown; the bid panel is
  told either way, so its line can say when the rest can come back.
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
  # While bidding is open, the auction is asked again at most this often.
  @early_recheck_seconds 30
  # A review holds for fifteen minutes; an unsent early one is asked for again first.
  @early_refresh_ms 8 * 60_000

  @impl true
  def update(%{early_refresh: review}, %{assigns: %{review: review, sent: sent}} = socket)
      when sent == %{},
      do: {:ok, socket |> assign(review: nil, early_state: nil) |> early_check()}

  def update(%{early_refresh: _review}, socket), do: {:ok, socket}

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
     |> assign_new(:after_claim, fn -> :wallet end)
     |> assign_new(:sent, fn -> %{} end)
     |> assign_new(:early, fn -> false end)
     |> assign_new(:early_state, fn -> nil end)
     |> early_check()}
  end

  @impl true
  def render(%{early: true} = assigns) do
    ~H"""
    <div id={@id} class="bid-early-return" phx-hook="AutolaunchReviewedSteps" phx-target={@myself}>
      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>
      <div :if={@review} class="bid-early-return__offer">
        <p :if={!@sent["exit"]}>
          <strong>
            {@review.envelope["arguments"]["stock_refunded_units"]} {@review.envelope["arguments"][
              "stock_symbol"
            ]}
          </strong>
          <UsdValue.usd
            amount={@review.envelope["arguments"]["stock_refunded_units"]}
            rate={@usd_rate}
          />
          comes back to your wallet now. The tokens this bid has bought are yours to claim after the auction.
        </p>
        <Regent.Primitives.button
          :if={!match?(%{outcome: :confirmed}, @sent["exit"])}
          type="button"
          data-reviewed-step="exit"
          variant={if @sent["exit"], do: "secondary", else: "primary"}
        >
          Get my unspent money back
        </Regent.Primitives.button>
        <p :if={@sent["exit"]} role="status" aria-live="polite">{early_progress(@sent["exit"])}</p>
        <Regent.Primitives.button
          :if={match?(%{outcome: :pending}, @sent["exit"])}
          type="button"
          phx-click="check_step"
          phx-value-step="exit"
          phx-target={@myself}
          variant="secondary"
        >
          Check again
        </Regent.Primitives.button>
      </div>
    </div>
    """
  end

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

  @impl true
  def handle_async(:early, {:ok, {wallet, result}}, socket) do
    socket = assign(socket, early_checked_at: System.monotonic_time(:second))

    cond do
      # The wallet changed or a review arrived while this was asked; the next
      # check starts from what is on screen now.
      wallet != socket.assigns.wallet or socket.assigns.review ->
        {:noreply, socket |> assign(early_state: nil) |> early_check()}

      result == :waiting ->
        {:noreply, socket |> assign(early_state: :waiting, notice: nil) |> early_told()}

      match?({:ok, _}, result) ->
        {:ok, review} = result

        {:noreply,
         socket
         |> assign(review: review, sent: %{}, notice: nil, early_state: :ready)
         |> published()
         |> early_told()
         |> early_later()}

      true ->
        {:noreply,
         socket
         |> assign(early_state: :refused, notice: notice(:error, refusal(elem(result, 1))))
         |> early_told()}
    end
  end

  def handle_async(:early, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         early_state: :refused,
         early_checked_at: System.monotonic_time(:second),
         notice: %{tone: :error, message: @generic}
       )}

  # The auction is asked while this row holds no review: first once a wallet
  # is known, then again, at most every half minute, while the answer was no.
  # A review is never replaced once a step of it has been sent.
  defp early_check(%{assigns: %{early: true} = assigns} = socket) do
    cond do
      is_nil(assigns.wallet) or assigns.review -> socket
      assigns.early_state == :checking -> socket
      !early_due?(assigns) -> socket
      true -> start_early(socket)
    end
  end

  defp early_check(socket), do: socket

  defp early_due?(%{early_state: nil}), do: true

  defp early_due?(%{early_checked_at: checked_at}),
    do: System.monotonic_time(:second) - checked_at >= @early_recheck_seconds

  defp start_early(socket) do
    %{auction: auction, bid: %{"bid_id" => bid_id}, wallet: wallet} = socket.assigns
    request = %{auction: auction, bid_id: bid_id}
    opts = opts(socket)

    socket
    |> assign(early_state: :checking)
    |> start_async(:early, fn -> {wallet, early_offer(request, wallet, opts)} end)
  end

  # Read-only until the auction would return the stock: only then is the
  # return reviewed.
  defp early_offer(request, wallet, opts) do
    case StockBidSettlementActions.exit_ready?(Map.put(request, :owner, wallet)) do
      {:ok, true} -> StockBidSettlementActions.prepare(request, wallet, opts)
      {:ok, false} -> :waiting
      {:error, _reason} = refused -> refused
    end
  end

  defp early_told(%{assigns: %{parent_id: parent, bid: %{"bid_id" => bid_id}}} = socket) do
    send_update(RobinhoodStockBidComponent,
      id: parent,
      early_return: {bid_id, socket.assigns.early_state}
    )

    socket
  end

  defp early_later(%{assigns: %{review: review}} = socket) do
    send_update_after(
      self(),
      __MODULE__,
      [id: socket.assigns.id, early_refresh: review],
      @early_refresh_ms
    )

    socket
  end

  defp early_progress(%{outcome: :pending}), do: "Sending your stock back…"

  defp early_progress(%{outcome: :confirmed}),
    do: "Your unspent stock is back in your wallet."

  defp early_progress(%{outcome: :reverted}),
    do:
      "That transaction was reverted, so nothing came back. Only the network fee was spent. You can send it again."

  defp early_progress(%{outcome: :unverified}),
    do:
      "That transaction did not return this bid, so it was not counted. Check your wallet's activity."

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    case StockBidSettlementActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket)) do
      {:ok, %{outcome: outcome}} ->
        socket
        |> assign(
          sent: Map.put(socket.assigns.sent, name, %{hash: hash, outcome: outcome}),
          notice: if(socket.assigns.early, do: nil, else: outcome_notice(name, outcome))
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
