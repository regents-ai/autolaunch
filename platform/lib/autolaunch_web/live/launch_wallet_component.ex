defmodule AutolaunchWeb.LaunchWalletComponent do
  @moduledoc """
  One compact card that takes a saved draft through its launch.

  The wallet Privy has selected drives everything here. Its address arrives as
  untrusted browser input and is proved against the mounted lease before any
  private fact is read or any durable write happens, so a wallet this account
  does not hold shows nothing and can neither review nor send.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash, a claimed step is never offered a second
  send, and success here means this server verified its own receipt evidence —
  never that the launch is already published.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.{Lab, LaunchActions}

  @chain_id 8453

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch back to a wallet on this account to continue.",
    invalid_address: "Switch back to a wallet on this account to continue.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    launch_preparation_unavailable: "Launching from your wallet is not open yet.",
    launch_snapshot_incomplete: "Base gave an incomplete answer. Try again in a moment.",
    launches_paused: "New launches are paused right now.",
    insufficient_regent: "This wallet does not hold enough REGENT for the launch fee.",
    launch_treasury_refused:
      "This address cannot be used as a launch treasury. Choose a different one on this draft and try again.",
    required_raise_unreachable:
      "This required raise is higher than an auction can reach. Lower it on this draft and try again.",
    strategy_not_bound:
      "This launch factory and its strategy do not match. Nothing was prepared.",
    launch_metadata_incomplete:
      "This draft is missing something the launch needs. Open it and save every field again.",
    launch_treasury_invalid:
      "This draft's treasury is not a usable address. Copy it from your wallet again and save the draft.",
    launch_raise_invalid: "This draft's required raise is not a usable amount.",
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

  # The refusals that mean this browser is not offering a wallet this account
  # holds, so no private fact and no control belongs on screen.
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
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign(:local_lab?, Lab.enabled?())
     |> assign(:treasury_report, current_report(assigns.draft))
     |> assign_new(:fresh_treasury_report_id, fn -> nil end)}
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
          Awaiting current chain confirmation. No REGENT approval or launch can be prepared on the official Safe path.
        </p>
        <p
          :if={freshly_unverified?(@treasury_report, @fresh_treasury_report_id)}
          data-treasury-verification-state="unverified"
        >
          Unverified. No REGENT approval or launch can be prepared on the official Safe path.
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

      <div :if={@authenticated && !@wallet} class="launch-wallet-empty">
        <p>Choose the wallet you want to launch from.</p>
        <Regent.Primitives.button type="button" data-launch-wallet-connect>Connect or switch wallet</Regent.Primitives.button>
      </div>

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
            <dt>Required raise</dt>
            <dd>{argument(@operation, "required_regent_raised")} REGENT</dd>
          </div>
          <div>
            <dt>Launch fee</dt>
            <dd>{fee_display(@operation)}</dd>
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
            <dd>{network_name(@operation)}</dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>{step_count(@operation)}</dd>
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
            <span>{step_label(step["step"], @operation)}</span>
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
          :if={@operation.state in [:reverted, :unverified]}
          class="launch-wallet-settled"
          role="alert"
        >
          {settled_copy(@operation)}
        </p>
        <p
          :if={
            @operation.state in [:not_sent, :cancelled, :expired, :invalidated, :submission_unknown]
          }
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
            This launch belongs to another wallet. Switch back to it to finish.
          </p>
          <Regent.Primitives.button
            :if={@operation.state == :submitted}
            type="button"
            phx-click="check_launch_step"
            phx-value-action-id={@operation.action_id}
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
      />
    </section>
    """
  end

  # The wallet Privy has selected, whenever it changes.
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

  def handle_event("wallet_press_restore", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.restore(socket, :launch, params, opts(socket))}

  def handle_event("launch_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

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

  # The browser's preflight is necessary input, never authority: the locked
  # dispatch proves the account still holds this wallet and that Base still
  # agrees, and only its winner is handed the exact reviewed bytes.
  def handle_event("sign_launch_step", %{"action-id" => action_id}, socket) do
    action_id
    |> Autolaunch.claim_launch_dispatch(socket.assigns.wallet, opts(socket))
    |> claimed(socket)
  end

  # The bound row goes on screen before Base is asked anything, so a read that
  # cannot answer leaves the transaction and its link exactly where they are.
  def handle_event("launch_submitted", params, socket) do
    {:noreply,
     AutolaunchWeb.WalletPressComponent.legacy_report(
       socket,
       :launch,
       params,
       opts(socket),
       __MODULE__,
       "autolaunch-launch:hash-durable"
     )}
  end

  def handle_event("check_launch_step", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.verify_launch_step(opts(socket)) |> settled(socket)}

  # The exact EIP-1193 rejection of a claimed step: the wallet was asked and said
  # no, so nothing was broadcast and the launch ends. Only that one code ends a
  # launch; any other reported code is not a rejection and changes nothing.
  def handle_event("launch_rejected", %{"action_id" => action_id, "code" => 4001}, socket),
    do: {:noreply, action_id |> Autolaunch.close_launch_not_sent(opts(socket)) |> settled(socket)}

  def handle_event("launch_rejected", _params, socket), do: {:noreply, socket}

  # The browser proved this claimed step never reached its wallet send, so the
  # same review becomes sendable again rather than ending.
  def handle_event("launch_dispatch_not_started", %{"action_id" => action_id}, socket),
    do:
      {:noreply,
       action_id |> Autolaunch.release_unstarted_launch_dispatch(opts(socket)) |> settled(socket)}

  def handle_event("cancel_launch_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.cancel_launch_review(opts(socket)) |> settled(socket)}

  def handle_event("start_new_launch", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> Autolaunch.start_new_launch(opts(socket)) |> settled(socket)}

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, notice: nil) |> cleared()}

  # Browser storage only prompts a restore; the owning account's row supplies
  # every fact. No row means the stored hint is stale, and saying so is what
  # stops it asking again on every reload.
  def handle_event("restore_launch_operation", _params, socket) do
    case Autolaunch.open_launch_operation(opts(socket)) do
      {:ok, %{operation: nil}} -> {:noreply, cleared(socket)}
      result -> {:noreply, settled(result, socket)}
    end
  end

  def handle_event("launch_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

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

  # Only the dispatch this claim just won may open a wallet, and it is read from
  # that claim's own result rather than from whatever this socket last held. A
  # refused, invalidated or repeated claim therefore hands the browser nothing.
  defp claimed({:ok, %{operation: %{state: :dispatched} = operation}} = result, socket) do
    {:noreply,
     result
     |> settled(socket)
     |> addressed("autolaunch-launch:send", %{
       action_id: operation.action_id,
       step: Atom.to_string(operation.step)
     })}
  end

  defp claimed(result, socket), do: {:noreply, settled(result, socket)}

  # The one acknowledgement the browser waits for before it drops its own copy of
  # a reported hash: this exact hash is durable on this exact step.
  # The whole reviewed sequence, so the browser can check that what it is asked to
  # send really belongs to the operation it is holding.
  defp published(%{assigns: %{operation: operation}} = socket) do
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

  defp lab_anchor(%{"metadata" => %{"lab" => nil}}), do: nil

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

  # No Ethereum wallet selected — disconnected, unlinked, or Solana in front of
  # the customer. That is the ordinary empty state, not a refusal.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.launch_wallet_state(address, opts(socket)) do
      {:ok, %{signer: signer}} -> socket |> assign(wallet: signer, notice: nil) |> restored()
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # The account's open launch is a server fact, so it is read whenever this wallet
  # is adopted. Browser storage only ever prompts a replay of a reported hash; a
  # new tab, another device or cleared storage must still see what is in flight.
  defp restored(%{assigns: %{operation: nil}} = socket) do
    case Autolaunch.open_launch_operation(opts(socket)) do
      {:ok, %{operation: nil}} -> socket
      {:ok, %{operation: _open}} = result -> settled(result, socket)
      _unavailable -> socket
    end
  end

  defp restored(socket), do: socket

  # Membership is a session fact. A wallet this account does not hold is not
  # adopted at all; one it does hold stays on screen with the reason.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, notice: notice(:info, reason))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp current_report(draft) do
    if Lab.enabled?(), do: nil, else: production_report(draft)
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

  defp network_name(%{envelope: %{"chain_id" => 31_337}}),
    do: "#{Autolaunch.ChainMode.label()} · chain 31337"

  defp network_name(_operation), do: "Base"

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

  defp step_count(operation) do
    case length(LaunchActions.steps(operation)) do
      1 -> "One transaction"
      2 -> "Two transactions"
    end
  end

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
  defp current_state(:reverted), do: "Reverted"
  defp current_state(:unverified), do: "Unresolved"
  defp current_state(:not_sent), do: "Not sent"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"
  defp current_state(:invalidated), do: "Out of date"
  defp current_state(:submission_unknown), do: "Unresolved"

  defp step_label("approval", _operation), do: "Allow the launch fee to be taken"
  defp step_label("launch", _operation), do: "Create the launch"

  # The exact customer sentence for a launch this server verified its own
  # evidence for. It deliberately promises no more than that: canonical public
  # confirmation is the finalized projection, not this.
  defp verified_copy(%{envelope: %{"chain_id" => 31_337}}),
    do: "The test transaction and launch record were verified. Test assets have no mainnet value."

  defp verified_copy(_operation),
    do:
      "Your transaction and launch record were verified. This launch will appear here when its onchain record is ready."

  defp settled_copy(%{state: :reverted, envelope: %{"chain_id" => 31_337}}),
    do: "This test transaction reverted. Nothing was created."

  defp settled_copy(%{state: :reverted}),
    do: "This transaction reverted on Base. Nothing was created."

  defp settled_copy(%{state: :unverified}),
    do: "This transaction did not record the launch you reviewed."

  defp settled_copy(%{state: :submission_unknown}),
    do: "This one is still unresolved. Check your wallet activity before you try it again."

  defp settled_copy(%{state: :not_sent} = operation),
    do: "Your wallet declined this." <> left_behind(operation)

  defp settled_copy(%{state: :cancelled}),
    do: AutolaunchWeb.WalletPressComponent.withdrawal_copy()

  defp settled_copy(%{state: :expired} = operation),
    do: "This review expired before the launch was sent." <> left_behind(operation)

  defp settled_copy(%{state: :invalidated, envelope: %{"chain_id" => 31_337}} = operation),
    do:
      "The fork changed before the launch was sent." <>
        left_behind(operation) <> ended_because(operation)

  defp settled_copy(%{state: :invalidated} = operation),
    do:
      "Base moved on before the launch was sent." <>
        left_behind(operation) <> ended_because(operation)

  # A review that ends after its allowance correction was already sent leaves
  # that exact allowance standing on Base, so claiming nothing was sent would be
  # false. The standing approval is named instead, and the next review's
  # exact-equality branch is what corrects it.
  defp left_behind(operation) do
    if LaunchActions.step_hash(operation, "approval"),
      do:
        " Your REGENT approval was already sent, so that allowance may still be active. A fresh review corrects that allowance exactly.",
      else: " Nothing was sent."
  end

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
      {"Required raise (atomic)", argument(operation, "required_regent_raised_atomic")},
      {"Launch fee (atomic)", argument(operation, "expected_launch_fee_atomic")},
      {"Reviewed block",
       "#{argument(operation, "block_number")} · #{argument(operation, "block_hash")}"},
      {"Calldata digest", operation.envelope["metadata"]["calldata_sha256"]}
    ] ++ Enum.map(LaunchActions.terms(), &{term_label(&1), Map.fetch!(terms, &1)})
  end

  defp term_label(key), do: key |> String.replace("_", " ") |> String.capitalize()

  defp fee_display(operation) do
    case argument(operation, "expected_launch_fee") do
      "0" -> "None right now"
      fee -> "#{fee} REGENT"
    end
  end

  # The browser reports a closed reason key as a string, never text of its own.
  # Only a key that proves the wallet was never asked to send may say nothing was
  # sent; everything else leaves the question open and says so.
  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you are using here, then try again. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do:
      "Your wallet may have sent this transaction. Check your wallet activity before you start another launch."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: copy(reason)}

  defp copy(:chain_unavailable) do
    if Lab.enabled?(),
      do: "The Base fork could not be read just now. Check that it is still running.",
      else: Map.fetch!(@copy, :chain_unavailable)
  end

  defp copy(:launch_snapshot_incomplete) do
    if Lab.enabled?(),
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
