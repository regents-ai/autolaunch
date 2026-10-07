defmodule AutolaunchWeb.LaunchWalletComponent do
  @moduledoc """
  One compact card that takes a saved draft through its launch on Base: one
  review, then the one launch transaction. There is no launch fee.

  The review, the step and its outcomes follow `AutolaunchWeb.LaunchSteps`.
  The review is saved (`Autolaunch.LaunchOperation`) so the launch it carries
  out is listed for this account: at once when this page sees it confirmed,
  otherwise when discovery finds it on Base. Off the local lab, the draft's
  treasury is verified here first.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.{Lab, LaunchActions}
  alias AutolaunchWeb.{LaunchSteps, OnchainSteps}

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    launch_preparation_unavailable: "Launching from your wallet is not open yet.",
    launch_snapshot_incomplete: "Base gave an incomplete answer. Try again in a moment.",
    launches_paused: "New launches are paused right now.",
    auction_limit_reached: "You already have an auction. One auction per account for now.",
    launch_treasury_refused:
      "This address cannot be used as a launch treasury. Choose a different one on this draft and try again.",
    strategy_not_bound:
      "This launch factory and its strategy do not match. Nothing was prepared.",
    launch_metadata_incomplete:
      "This draft is missing something the launch needs. Open it and save every field again.",
    launch_treasury_invalid:
      "This draft's treasury is not a usable address. Copy it from your wallet again and save the draft.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now.",
    treasury_not_verified: "This Safe is not currently verified as a 2-of-3 treasury.",
    treasury_report_missing: "Verify the deployed treasury address before review.",
    treasury_security_changed: "The treasury configuration changed. Verify it again.",
    treasury_source_reorged: "The treasury proof block is no longer canonical. Verify it again.",
    treasury_observation_recorded: "Treasury observation recorded from canonical Base reads."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket),
    do: {:ok, socket |> LaunchSteps.init() |> assign(fresh_treasury_report_id: nil)}

  # The review on the page, checked against the chain again once it is ten
  # minutes old (`AutolaunchWeb.LaunchSteps.rechecked/4`).
  @impl true
  def update(%{refresh_review: review_id}, socket),
    do: {:ok, LaunchSteps.refreshed(socket, review_id, current(socket), &prepare(socket, &1))}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(local_lab?: Lab.test_chain?(), treasury_report: current_report(assigns.draft))
     |> OnchainSteps.adopt()
     |> LaunchSteps.followed()}
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
      <p class="launch-wallet-notice" role="status" hidden={!@notice}>{@notice}</p>

      <section
        :if={!@local_lab?}
        id={"#{@id}-treasury"}
        class="treasury-verification"
        aria-label="Treasury verification"
        data-agent-tools="autolaunch_verify_treasury"
        phx-hook="AgentTools"
      >
        <h4>Verify immutable treasury</h4>
        <p class="launch-wallet-mono">{RegentFormat.short_address(@draft.treasury)}</p>
        <p
          :if={freshly_verified?(@treasury_report, @fresh_treasury_report_id)}
          data-treasury-verification-state="verified"
        >
          Verified 2-of-3 Safe at canonical Base block {@treasury_report.source_block_number}.
        </p>
        <p
          :if={awaiting_current_chain?(@treasury_report, @fresh_treasury_report_id)}
          data-treasury-verification-state="awaiting-current-chain-confirmation"
        >
          Awaiting current chain confirmation. No launch can be prepared on the official Safe path.
        </p>
        <p
          :if={freshly_unverified?(@treasury_report, @fresh_treasury_report_id)}
          data-treasury-verification-state="unverified"
        >
          Unverified. No launch can be prepared on the official Safe path.
        </p>
        <form class="rg-field" phx-submit="verify_treasury" phx-target={@myself}>
          <label>USDC receipt transaction <input name="usdc" autocomplete="off" /></label>
          <label>REGENT receipt transaction <input name="regent" autocomplete="off" /></label>
          <label>Outbound Safe execution transaction <input name="outbound" autocomplete="off" /></label>
          <Regent.Primitives.button type="submit">Verify deployed address on Base</Regent.Primitives.button>
        </form>
      </section>

      <p :if={!@authenticated} class="launch-wallet-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">Sign in to launch</Regent.Primitives.button>
      </p>

      <div class="launch-wallet-open" hidden={!(@authenticated && !@review)}>
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
              <dt>Minimum REGENT raised</dt>
              <dd>{@prepared.facts["required_regent_raised"]} REGENT</dd>
            </div>
            <div>
              <dt>Launch fee</dt>
              <dd>None</dd>
            </div>
            <div>
              <dt>Treasury</dt>
              <dd class="launch-wallet-mono">{@prepared.facts["treasury"]}</dd>
            </div>
            <div>
              <dt>Treasury custody</dt>
              <dd>{custody_label(@prepared.facts["treasury_path"])}</dd>
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

          <dl class="launch-wallet-terms">
            <div>
              <dt>Supply</dt>
              <dd>{allocation_display(@prepared.facts["terms"])}</dd>
            </div>
            <div>
              <dt>Pool fee</dt>
              <dd>{pool_fee(@prepared.facts["terms"])}</dd>
            </div>
            <div>
              <dt>Network fee</dt>
              <dd>Shown in your wallet before confirmation.</dd>
            </div>
          </dl>

          <Regent.Primitives.disclosure
            id={"#{@id}-exact-values"}
            summary="Exact values"
            class="launch-wallet-details"
          >
            <p>
              Every launch uses these same terms. Bidding, claiming, and pool opening follow fixed block delays.
            </p>
            <dl>
              <div :for={{label, value} <- exact_values(@prepared.facts, @review)}>
                <dt>{label}</dt>
                <dd class="launch-wallet-mono">{value}</dd>
              </div>
            </dl>
          </Regent.Primitives.disclosure>
        <% end %>

        <LaunchSteps.progress
          steps={@steps}
          review={@review}
          mismatch={@mismatch}
          press_note={@press_note}
          target={@myself}
        />
      </section>

      <section :if={@launched} class="launch-wallet-settled" role="status">
        <p>{launched_copy(@local_lab?)}</p>
        <p>
          <.link :if={@launched["path"]} navigate={@launched["path"]}>Open the auction</.link>
          · Auction <span class="launch-wallet-mono">{@launched["auction"]}</span>
        </p>
        <p>
          Bidding opens at block {@launched["start_block"]} and ends at block {@launched["end_block"]}.
        </p>
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
    do: {:noreply, LaunchSteps.failed(socket, params, :launch)}

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  # The saved review is withdrawn too, so nothing is later listed from it.
  def handle_event("cancel_review", _params, %{assigns: %{prepared: prepared}} = socket) do
    if prepared, do: LaunchActions.cancel(prepared.action_id, opts(socket))
    {:noreply, LaunchSteps.withdrawn(socket)}
  end

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> assign(launched: nil) |> LaunchSteps.withdrawn()}

  def handle_event("verify_treasury", hashes, socket) do
    if socket.assigns.local_lab? do
      {:noreply, socket}
    else
      {:noreply, verify_treasury(hashes, socket)}
    end
  end

  def handle_event(
        "agent_call",
        %{"tool" => "autolaunch_verify_treasury", "input" => input},
        socket
      )
      when is_map(input) do
    socket = verify_treasury(input, socket)

    outcome =
      if freshly_verified?(
           socket.assigns.treasury_report,
           socket.assigns.fresh_treasury_report_id
         ),
         do: "verified",
         else: "not_verified"

    {:reply, %{outcome: outcome, message: socket.assigns.notice}, socket}
  end

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do:
      {:noreply,
       OnchainSteps.checked(
         socket,
         hash,
         result,
         &LaunchSteps.list(&1, :launch, &2),
         &LaunchSteps.reverted(&1, &2, current(socket), fn signer -> prepare(socket, signer) end)
       )}

  def handle_async({:listed, _hash}, answer, socket),
    do: {:noreply, LaunchSteps.listed(socket, answer)}

  defp prepare(socket, signer) do
    case LaunchActions.prepare(socket.assigns.draft.id, signer, opts(socket)) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, copy(refusal(error))}
    end
  end

  defp current(socket), do: &LaunchActions.current(&1, opts(socket))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  # Treasury verification

  defp current_report(draft) do
    if Lab.test_chain?(), do: nil, else: production_report(draft)
  end

  defp verify_treasury(hashes, socket) do
    result =
      Autolaunch.observe_treasury_security(
        socket.assigns.draft.treasury,
        Map.take(hashes, ["usdc", "regent", "outbound"]),
        actor: actor(socket)
      )

    case result do
      {:ok, report} ->
        assign(socket,
          treasury_report: report,
          fresh_treasury_report_id: report.id,
          notice: copy(:treasury_observation_recorded)
        )

      {:error, error} ->
        assign(socket, fresh_treasury_report_id: nil, notice: copy(refusal(error)))
    end
  end

  defp production_report(%{treasury: treasury}) when is_binary(treasury) do
    case Autolaunch.current_treasury_security(treasury, actor: nil) do
      {:ok, report} -> report
      _error -> nil
    end
  end

  defp production_report(_draft), do: nil

  defp freshly_verified?(%{id: id, verification_state: :verified}, id), do: true
  defp freshly_verified?(_report, _fresh_report_id), do: false

  defp freshly_unverified?(nil, _fresh_report_id), do: true
  defp freshly_unverified?(%{id: id, verification_state: state}, id), do: state != :verified
  defp freshly_unverified?(_report, _fresh_report_id), do: false

  defp awaiting_current_chain?(%{id: id}, fresh_report_id), do: id != fresh_report_id
  defp awaiting_current_chain?(_report, _fresh_report_id), do: false

  # The review

  # What this page says of a launch it saw confirmed and listed. The auction
  # page follows once the site has read the auction.
  defp launched_copy(true),
    do: "The test launch was created and listed. Test assets have no mainnet value."

  defp launched_copy(false), do: "Your launch was created and listed."

  defp allocation_display(terms) do
    "#{share(terms, "auction_allocation")} auction · " <>
      "up to #{share(terms, "reserve_allocation")} for the pool · " <>
      "#{share(terms, "pending_allocation")} or more vests to the treasury over a year"
  end

  # The three allocations are the whole supply, so each share is read from the
  # reviewed terms rather than restated as a literal here.
  defp share(terms, key) do
    total =
      Enum.sum(
        Enum.map(~w(auction_allocation reserve_allocation pending_allocation), &number(terms, &1))
      )

    "#{div(number(terms, key) * 100, total)}%"
  end

  # Uniswap states a static pool fee in hundredths of a basis point.
  defp pool_fee(terms),
    do: "#{:erlang.float_to_binary(number(terms, "pool_fee") / 10_000, decimals: 2)}%"

  defp number(terms, key), do: terms |> Map.fetch!(key) |> String.to_integer()

  # Everything technical, behind the one disclosure: raw addresses, the exact
  # target, the reviewed block, the block counts and the digest of the exact
  # bytes this wallet is being asked to sign.
  defp exact_values(facts, review) do
    terms = facts["terms"]

    [
      {"Factory", facts["factory"]},
      {"Strategy", facts["strategy"]},
      {"Treasury", facts["treasury"]},
      {"Reviewed block", "#{facts["block_number"]} · #{facts["block_hash"]}"},
      {"Calldata digest", LaunchSteps.digest(review)}
    ] ++ Enum.map(LaunchActions.terms(), &{term_label(&1), Map.fetch!(terms, &1)})
  end

  defp term_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp copy(:chain_unavailable) do
    if Lab.test_chain?(),
      do: "The Base fork could not be read just now. Check that it is still running.",
      else: Map.fetch!(@copy, :chain_unavailable)
  end

  defp copy(:launch_snapshot_incomplete) do
    if Lab.test_chain?(),
      do: "The Base fork returned an incomplete answer. Check that it is still running.",
      else: Map.fetch!(@copy, :launch_snapshot_incomplete)
  end

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp custody_label("safe"), do: "2-of-3 Safe"
  defp custody_label("contract"), do: "Existing contract"
  defp custody_label("eoa"), do: "Single-key EOA"
end
