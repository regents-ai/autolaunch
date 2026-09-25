defmodule AutolaunchWeb.LaunchWalletComponent do
  @moduledoc """
  One compact card that takes a saved draft through its launch.

  The wallet the customer signed in with drives everything here, read from the
  mounted lease. A press opens that wallet, or Privy's connect step when this tab
  has not connected it, and a note names both wallets while the browser is on
  another one.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash, a claimed step is never offered a second
  send, and success here means this server verified its own receipt evidence —
  never that the launch is already published.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.{Lab, LaunchActions}
  alias AutolaunchWeb.SignedInWallet

  @chain_id 8453

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "You are now signed in with a different wallet. Reload the page to continue.",
    invalid_address:
      "You are now signed in with a different wallet. Reload the page to continue.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    launch_preparation_unavailable: "Launching from your wallet is not open yet.",
    launch_snapshot_incomplete: "Base gave an incomplete answer. Try again in a moment.",
    launches_paused: "New launches are paused right now.",
    launch_treasury_refused:
      "This address cannot be used as a launch treasury. Choose a different one on this draft and try again.",
    required_raise_unreachable:
      "This minimum raise is higher than an auction can reach. Lower it on this draft and try again.",
    strategy_not_bound:
      "This launch factory and its strategy do not match. Nothing was prepared.",
    launch_metadata_incomplete:
      "This draft is missing something the launch needs. Open it and save every field again.",
    launch_treasury_invalid:
      "This draft's treasury is not a usable address. Copy it from your wallet again and save the draft.",
    launch_raise_invalid: "This draft's minimum raise is not a usable amount.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now.",
    launch_step_moved: "This launch moved on while you were looking. Check it again.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this launch is waiting for.",
    launch_operation_not_found: "That launch is no longer open.",
    treasury_not_verified: "This Safe is not currently verified as a 2-of-3 treasury.",
    treasury_report_missing: "Verify the deployed treasury address before review.",
    treasury_security_changed: "The treasury configuration changed. Verify it again.",
    treasury_source_reorged: "The treasury proof block is no longer canonical. Verify it again.",
    treasury_observation_recorded: "Treasury observation recorded from canonical Base reads."
  }

  @generic "That did not go through. Try again in a moment."

  # The refusals that mean the session no longer vouches for the signed-in
  # wallet, so no private fact and no control belongs on screen.
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket) do
    {:ok, AutolaunchWeb.WalletPressComponent.consume(socket, lease, result)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> AutolaunchWeb.WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:browser_wallets, fn -> [] end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign(:local_lab?, Lab.test_chain?())
     |> assign(:treasury_report, current_report(assigns.draft))
     |> assign_new(:fresh_treasury_report_id, fn -> nil end)
     |> SignedInWallet.adopt(&adopt/2)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="launch-wallet"
      data-wallet-scope={AutolaunchWeb.WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchLaunchWallet"
      phx-target={@myself}
    >
      <.notice :if={@notice} notice={@notice} />

      <section :if={!@local_lab?} class="treasury-verification" aria-label="Treasury verification">
        <h4>Verify immutable treasury</h4>
        <p class="launch-wallet-mono">{short(@draft.treasury)}</p>
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

      <div :if={@authenticated && @wallet && !@operation} class="launch-wallet-open">
        <p class="launch-wallet-hint">
          Launching from {short(@wallet)}. Your wallet confirms every step.
        </p>
        <Regent.Primitives.button
          class="launch-wallet-primary"
          type="button"
          phx-click="review_launch"
          phx-target={@myself}
        >
          Review launch
        </Regent.Primitives.button>
      </div>

      <section
        :if={@operation && AutolaunchWeb.WalletPressComponent.scope(assigns)}
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label="Launch review"
      >
        <h4>Review this launch</h4>

        <dl>
          <div>
            <dt>Token</dt>
            <dd>{argument(@operation, "name")} · {argument(@operation, "symbol")}</dd>
          </div>
          <div>
            <dt>Minimum REGENT raised</dt>
            <dd>{argument(@operation, "required_regent_raised")} REGENT</dd>
          </div>
          <div>
            <dt>Launch fee</dt>
            <dd>None</dd>
          </div>
          <div>
            <dt>Treasury</dt>
            <dd class="launch-wallet-mono">{argument(@operation, "treasury")}</dd>
          </div>
          <div>
            <dt>Treasury custody</dt>
            <dd>{custody_label(@draft.treasury_path)}</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@operation.signer)}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{Lab.network_name(@operation.envelope["chain_id"])}</dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>One transaction</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@operation.envelope["risk_copy"]}</p>

        <dl class="launch-wallet-terms">
          <div>
            <dt>Supply</dt>
            <dd>{allocation_display(@operation)}</dd>
          </div>
          <div>
            <dt>Pool fee</dt>
            <dd>{pool_fee(argument(@operation, "terms"))}</dd>
          </div>
          <div>
            <dt>Network fee</dt>
            <dd>Shown in your wallet before confirmation.</dd>
          </div>
        </dl>

        <%!-- The list styling drops list semantics, so the role is stated. --%>
        <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
          <li :for={step <- LaunchActions.steps(@operation)} data-step={step["step"]}>
            <span>{step_label(step["step"])}</span>
            <span class="launch-wallet-step-state">{step_state(@operation, step["step"])}</span>
            <.transaction
              hash={LaunchActions.step_hash(@operation, step["step"])}
              chain_id={@operation.envelope["chain_id"]}
            />
          </li>
        </ol>

        <p :if={@operation.state == :chain_verified} class="launch-wallet-settled" role="status">
          {verified_copy(@operation)}
        </p>
        <p
          :if={@operation.state in [:cancelled, :expired, :invalidated]}
          class="launch-wallet-settled"
          role="status"
        >
          {settled_copy(@operation)}
        </p>

        <Regent.Primitives.disclosure
          id={"#{@id}-exact-values"}
          summary="Exact values"
          class="launch-wallet-details"
        >
          <p>
            Every launch uses these same terms. Bidding, claiming, and pool opening follow fixed block delays.
          </p>
          <dl>
            <div :for={{label, value} <- exact_values(@operation)}>
              <dt>{label}</dt>
              <dd class="launch-wallet-mono">{value}</dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>

        <div class="launch-wallet-controls">
          <SignedInWallet.note
            :if={sendable?(@operation, @wallet)}
            signed_in={@wallet}
            browser={@browser_wallets}
          />
          <Regent.Primitives.button
            :if={sendable?(@operation, @wallet)}
            type="button"
            data-launch-wallet-send={@operation.action_id}
            data-wallet-step={@operation.step}
            data-launch-wallet-signer={@operation.signer}
          >
            Confirm in wallet
          </Regent.Primitives.button>
          <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
            This launch belongs to another wallet. Sign in with that wallet to finish.
          </p>
          <Regent.Primitives.button
            :if={@operation.state == :submitted}
            type="button"
            phx-click="wallet_press_verify"
            phx-value-action_id={@operation.action_id}
            phx-value-press_id={submitted_press(@operation)}
            phx-target={@myself}
            variant="secondary"
          >
            Check again
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state == :prepared && !started?(@operation)}
            type="button"
            phx-click="cancel_launch_review"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Cancel
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state in [:dispatched, :submitted]}
            type="button"
            phx-click="start_new_launch"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Start something else
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.terminal_at}
            type="button"
            phx-click="clear_launch"
            phx-target={@myself}
            variant="secondary"
          >
            Done
          </Regent.Primitives.button>
        </div>
      </section>
      <AutolaunchWeb.WalletPressComponent.history
        :if={AutolaunchWeb.WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
        label={fn step, _operation -> step_label(step) end}
      />
    </section>
    """
  end

  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.dispatch(
         socket,
         :launch,
         params,
         opts(socket),
         __MODULE__
       )}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.report(
         socket,
         :launch,
         params,
         opts(socket),
         __MODULE__
       )}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.verify(
         socket,
         :launch,
         params,
         opts(socket),
         __MODULE__
       )}

  # The wallets this tab has connected, whenever they change: only for the note.
  def handle_event("browser_wallets", params, socket),
    do: {:noreply, assign(socket, browser_wallets: SignedInWallet.reported(params))}

  def handle_event("review_launch", _params, socket) do
    {:noreply,
     socket.assigns.draft.id
     |> Autolaunch.prepare_launch(socket.assigns.wallet, opts(socket))
     |> settled(socket)}
  end

  def handle_event("verify_treasury", hashes, socket) do
    if socket.assigns.local_lab? do
      {:noreply, socket}
    else
      do_verify_treasury(hashes, socket)
    end
  end

  def handle_event("cancel_launch_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.cancel_launch_review(opts(socket)) |> settled(socket)}

  def handle_event("start_new_launch", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.start_new_launch(opts(socket)) |> settled(socket)}

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, notice: nil) |> cleared()}

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p class="launch-wallet-notice" role={if @notice.tone == :error, do: "alert", else: "status"}>
      {@notice.message}
    </p>
    """
  end

  attr :hash, :string, default: nil
  attr :chain_id, :integer, default: @chain_id

  defp transaction(assigns) do
    ~H"""
    <a
      :if={@hash && @chain_id == 8453}
      class="launch-wallet-mono"
      href={"https://basescan.org/tx/#{@hash}"}
      target="_blank"
      rel="noopener"
      aria-label="View this transaction on Basescan"
    >
      {short_hash(@hash)}
    </a>
    <span :if={@hash && @chain_id == 31_337} class="launch-wallet-mono" data-local-transaction-hash>
      {short_hash(@hash)}
    </span>
    """
  end

  # The closed set this card maps a browser value through. Nothing here builds an
  # atom from what the browser sent.
  # One open launch per account, so a row belonging to another draft is named as
  # that rather than shown on this card.
  defp settled({:ok, %{operation: %{launch_draft_id: draft_id} = operation}}, socket) do
    if draft_id == socket.assigns.draft.id do
      socket |> assign(operation: operation, notice: nil) |> published()
    else
      socket |> assign(operation: nil, notice: nil) |> cleared()
    end
  end

  defp settled({:ok, %{operation: nil}}, socket),
    do: socket |> assign(operation: nil) |> cleared()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  # The one acknowledgement the browser waits for before it drops its own copy of
  # a reported hash: this exact hash is durable on this exact step.
  # The whole reviewed sequence, so the browser can check that what it is asked to
  # send really belongs to the operation it is holding.
  defp published(%{assigns: %{operation: operation}} = socket) do
    send(self(), {:launch_review, :open})

    addressed(socket, "autolaunch-launch:operation", %{
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: lab_anchor(operation.envelope),
      terminal: not is_nil(operation.terminal_at),
      steps: LaunchActions.steps(operation)
    })
  end

  defp lab_anchor(envelope),
    do: %{
      block_number: envelope["arguments"]["block_number"],
      block_hash: envelope["arguments"]["block_hash"]
    }

  defp cleared(socket), do: addressed(socket, "autolaunch-launch:cleared", %{})

  # A pushed event reaches every hook in the LiveView, and a founder with several
  # saved drafts has one card each. Naming the card the event belongs to is what
  # keeps a dispatch from opening every other card's wallet as well.
  defp addressed(socket, event, payload),
    do:
      push_event(
        socket,
        event,
        payload
        |> Map.put(:card, socket.assigns.id)
        |> Map.put(:component_id, socket.assigns.id)
      )

  # Signed out: the card reads nothing and says nothing.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.launch_wallet_state(address, opts(socket)) do
      {:ok, %{signer: signer}} -> assign(socket, wallet: signer, notice: nil)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # Membership is a session fact. A wallet the session no longer vouches for is
  # not adopted at all; the signed-in one stays on screen with the reason.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, notice: notice(:info, reason), signed_in_for: nil)

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp current_report(draft) do
    if Lab.test_chain?(), do: nil, else: production_report(draft)
  end

  defp do_verify_treasury(hashes, socket) do
    result =
      Autolaunch.observe_treasury_security(
        socket.assigns.draft.treasury,
        Map.take(hashes, ["usdc", "regent", "outbound"]),
        actor: actor(socket)
      )

    case result do
      {:ok, report} ->
        {:noreply,
         assign(socket,
           treasury_report: report,
           fresh_treasury_report_id: report.id,
           notice: notice(:info, :treasury_observation_recorded)
         )}

      {:error, error} ->
        {:noreply,
         assign(socket,
           fresh_treasury_report_id: nil,
           notice: notice(:error, refusal(error))
         )}
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

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  defp started?(operation),
    do:
      Enum.any?(
        LaunchActions.steps(operation),
        &LaunchActions.step_hash(operation, &1["step"])
      )

  # Where the sequence has got to, read from the operation's own step and state.
  defp step_state(%{step: step} = operation, step_name) do
    cond do
      Atom.to_string(step) == step_name -> current_state(operation.state)
      LaunchActions.step_hash(operation, step_name) -> "Verified"
      true -> "Waiting"
    end
  end

  defp current_state(:prepared), do: "Ready"
  defp current_state(:dispatched), do: "In your wallet"
  defp current_state(:submitted), do: "Sent"
  defp current_state(:chain_verified), do: "Verified"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"
  defp current_state(:invalidated), do: "Out of date"

  defp step_label("launch"), do: "Create the launch"

  # The exact customer sentence for a launch this server verified its own
  # evidence for. It deliberately promises no more than that: canonical public
  # confirmation is the finalized projection, not this.
  defp verified_copy(%{envelope: %{"chain_id" => chain_id}}) do
    if Lab.test_chain?(chain_id),
      do:
        "The test transaction and launch record were verified. Test assets have no mainnet value.",
      else:
        "Your transaction and launch record were verified. This launch will appear here when its onchain record is ready."
  end

  defp settled_copy(%{state: :cancelled}),
    do: AutolaunchWeb.WalletPressComponent.withdrawal_copy()

  defp settled_copy(%{state: :expired}),
    do: "This review expired before the launch was sent. Nothing was sent."

  defp settled_copy(%{state: :invalidated, envelope: %{"chain_id" => chain_id}} = operation),
    do: invalidated_copy(Lab.test_chain?(chain_id)) <> ended_because(operation)

  defp invalidated_copy(true),
    do: "The fork changed before the launch was sent. Nothing was sent."

  defp invalidated_copy(false), do: "Base moved on before the launch was sent. Nothing was sent."

  defp ended_because(%{reason: reason}) when is_binary(reason),
    do: " Review it again: #{reason}."

  defp ended_because(_operation), do: ""

  defp allocation_display(operation) do
    terms = argument(operation, "terms")

    "#{share(terms, "auction_allocation")} auction · " <>
      "#{share(terms, "reserve_allocation")} pool reserve · " <>
      "#{share(terms, "pending_allocation")} escrow until settlement"
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
  # target, the reviewed block, the Q96 values, the block counts and the digest
  # of the exact bytes this wallet is being asked to sign.
  defp exact_values(operation) do
    terms = argument(operation, "terms")

    [
      {"Factory", argument(operation, "factory")},
      {"Strategy", argument(operation, "strategy")},
      {"Treasury", argument(operation, "treasury")},
      {"Minimum raise (atomic)", argument(operation, "required_regent_raised_atomic")},
      {"Reviewed block",
       "#{argument(operation, "block_number")} · #{argument(operation, "block_hash")}"},
      {"Calldata digest", operation.envelope["metadata"]["calldata_sha256"]}
    ] ++ Enum.map(LaunchActions.terms(), &{term_label(&1), Map.fetch!(terms, &1)})
  end

  defp term_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  # The press whose transaction the card is waiting on: the submitted attempt of
  # the current step, whose hash the chain has not answered about yet.
  defp submitted_press(operation),
    do:
      Enum.find_value(
        operation.attempts,
        &(&1.state == :submitted and &1.step == operation.step and &1.id)
      )

  defp notice(tone, reason), do: %{tone: tone, message: copy(reason)}

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

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp custody_label(:safe), do: "2-of-3 Safe"
  defp custody_label(:contract), do: "Existing contract"
  defp custody_label(:eoa), do: "Single-key EOA"

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
