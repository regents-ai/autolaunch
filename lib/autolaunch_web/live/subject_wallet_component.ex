defmodule AutolaunchWeb.SubjectWalletComponent do
  @moduledoc """
  One compact card for everything a wallet can do on a subject.

  The wallet Privy has selected drives everything here. Its address arrives as
  untrusted browser input and is proved against the mounted lease before any
  private fact is read or any durable write happens, so a wallet this account
  does not hold shows no balances and can neither review nor send.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash, and a claimed step is never offered a
  second send.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.SubjectWalletActions

  @chain_id 8453

  @actions [
    %{kind: :stake, label: "Stake", verb: "Stake"},
    %{kind: :unstake, label: "Unstake", verb: "Unstake"},
    %{kind: :claim, label: "Claim", verb: "Claim"},
    %{kind: :claim_all, label: "Claim all", verb: "Claim everything"},
    %{kind: :pay, label: "Pay", verb: "Pay"},
    %{kind: :sweep, label: "Sweep", verb: "Sweep"},
    %{kind: :set_note, label: "Label", verb: "Set label"}
  ]

  @amount_kinds [:stake, :unstake, :pay]
  @asset_kinds [:claim, :pay, :sweep]
  @receiver_kinds [:pay, :sweep, :set_note]

  @assets [
    %{id: "subject", key: :subject, label: "SUBJECT"},
    %{id: "usdc", key: :usdc, label: "USDC"},
    %{id: "regent", key: :regent, label: "REGENT"}
  ]

  @copy %{
    authentication_required: "Sign in to use your wallet here.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch back to a wallet on this account to continue.",
    invalid_address: "Switch back to a wallet on this account to continue.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    subject_not_found: "This subject is no longer available.",
    subject_unavailable: "This subject could not be read just now.",
    subject_not_on_base: "This subject is not on Base.",
    subject_token_unavailable: "This subject has no token yet.",
    subject_splitter_unavailable: "This subject is not sharing revenue yet.",
    subject_treasury_unavailable: "This subject has no treasury yet.",
    canonical_receiver_unavailable: "This subject has no payment address yet.",
    receiver_not_canonical: "This payment address is not the launch's own. Nothing was prepared.",
    splitter_subject_mismatch: "This subject's revenue split does not match its token.",
    splitter_usdc_mismatch: "This subject's revenue split does not match its token.",
    splitter_regent_mismatch: "This subject's revenue split does not match its token.",
    splitter_treasury_mismatch: "This subject's revenue split does not match its treasury.",
    receiver_splitter_mismatch: "This payment address does not belong to this subject.",
    receiver_subject_mismatch: "This payment address does not belong to this subject.",
    receiver_usdc_mismatch: "This payment address does not belong to this subject.",
    receiver_regent_mismatch: "This payment address does not belong to this subject.",
    receiver_treasury_mismatch: "This payment address does not belong to this subject.",
    subject_wallet_preparation_unavailable: "Wallet actions are not open on this subject yet.",
    amount_above_balance: "That is more than this wallet holds.",
    amount_above_stake: "That is more than this wallet has staked.",
    nothing_claimable: "There is nothing to claim right now.",
    nothing_to_sweep: "There is nothing waiting at this address right now.",
    not_note_editor: "Only the launch treasury can change this label.",
    invalid_note: "Use at most 32 bytes of ordinary text.",
    invalid_amount: "Enter an amount using this asset's decimal places.",
    unsupported_asset: "Choose SUBJECT, USDC, or REGENT.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this action is waiting for.",
    subject_wallet_operation_not_found: "That action is no longer open."
  }

  @generic "That did not go through. Try again in a moment."

  # The refusals that mean this browser is not offering a wallet this account
  # holds, so no private fact and no control belongs on screen.
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:state, fn -> nil end)
     |> assign_new(:kind, fn -> :stake end)
     |> assign_new(:asset, fn -> "usdc" end)
     |> assign_new(:amount, fn -> "" end)
     |> assign_new(:note, fn -> "" end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:operation, fn -> nil end)
     |> assign(assets: @assets, action_list: @actions)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="subject-wallet"
      phx-hook="AutolaunchSubjectWallet"
      phx-target={@myself}
    >
      <header class="subject-wallet-heading">
        <h2>Your wallet on this subject</h2>
        <p>
          Stake, claim, and pay from the wallet you have selected. Your wallet confirms every step.
        </p>
      </header>

      <.notice :if={@notice} notice={@notice} />

      <p :if={!@authenticated} class="subject-wallet-empty">
        <button type="button" data-account-target="sign-in">Sign in to continue</button>
      </p>

      <div :if={@authenticated && !@wallet} class="subject-wallet-empty">
        <p>Choose the wallet you want to use here.</p>
        <button type="button" data-subject-wallet-connect>Connect or switch wallet</button>
      </div>

      <div :if={@authenticated && @wallet && @state} class="subject-wallet-body">
        <dl class="subject-wallet-balances">
          <div>
            <dt>Wallet</dt>
            <dd class="subject-wallet-mono">{short(@wallet)}</dd>
          </div>
          <div :for={asset <- @assets}>
            <dt>{asset.label}</dt>
            <dd>{@state.balances[asset.key]}</dd>
          </div>
          <div>
            <dt>Staked</dt>
            <dd>{@state.staked}</dd>
          </div>
        </dl>

        <div :if={!@operation} class="subject-wallet-choose">
          <%!-- A small selector, not a tab widget: each button switches the one form below. --%>
          <div class="subject-wallet-actions" role="group" aria-label="Choose an action">
            <button
              :for={action <- @action_list}
              type="button"
              id={"#{@id}-action-#{action.kind}"}
              class="subject-wallet-action"
              aria-pressed={to_string(@kind == action.kind)}
              phx-click="select_subject_action"
              phx-value-kind={action.kind}
              phx-target={@myself}
            >
              {action.label}
            </button>
          </div>

          <form
            id={"#{@id}-form"}
            phx-change="subject_form_changed"
            phx-submit="review_subject_action"
            phx-target={@myself}
          >
            <div :if={asset_kind?(@kind)} class="subject-wallet-field">
              <label for={"#{@id}-asset"}>Asset</label>
              <select id={"#{@id}-asset"} name="asset">
                <option :for={asset <- @assets} value={asset.id} selected={asset.id == @asset}>
                  {asset.label}
                </option>
              </select>
            </div>

            <div :if={amount_kind?(@kind)} class="subject-wallet-field">
              <label for={"#{@id}-amount"}>Amount</label>
              <div class="subject-wallet-amount">
                <input
                  id={"#{@id}-amount"}
                  name="amount"
                  value={@amount}
                  inputmode="decimal"
                  autocomplete="off"
                  placeholder="0.0"
                />
                <button type="button" phx-click="fill_subject_amount" phx-target={@myself}>
                  Max
                </button>
              </div>
            </div>

            <div :if={@kind == :set_note} class="subject-wallet-field">
              <label for={"#{@id}-note"}>Label</label>
              <input
                id={"#{@id}-note"}
                name="note"
                value={@note}
                maxlength="32"
                autocomplete="off"
                placeholder="Front desk"
              />
              <p class="subject-wallet-hint">
                Up to 32 bytes of ordinary text. Leave it empty to clear the label.
              </p>
            </div>

            <p :if={@kind == :stake} class="subject-wallet-hint">{stake_timing()}</p>

            <p :if={@kind == :claim_all} class="subject-wallet-hint">
              Collects every asset this subject has already set aside for this wallet.
            </p>

            <p :if={@kind == :sweep} class="subject-wallet-hint">
              Routes a balance already waiting at this subject's payment address. Nothing is sent to
              your wallet, and another sweep before yours can make this fail.
            </p>

            <p :if={receiver_kind?(@kind) && @state.receiver} class="subject-wallet-hint">
              Payment address {short(@state.receiver.address)} · Label {note_label(
                @state.receiver.note
              )}
            </p>

            <button class="subject-wallet-primary" type="submit" disabled={!ready?(assigns)}>
              Review {String.downcase(verb(@kind))}
            </button>
          </form>
        </div>

        <section
          :if={@operation}
          id={"#{@id}-review"}
          class="subject-wallet-review"
          aria-label="Action review"
        >
          <h3>{verb(@operation.kind)}</h3>
          <dl>
            <div :if={amount_display(@operation)}>
              <dt>Amount</dt>
              <dd>{amount_display(@operation)} {argument(@operation, "symbol")}</dd>
            </div>
            <div :if={@operation.kind == :claim}>
              <dt>Asset</dt>
              <dd>{argument(@operation, "symbol")}</dd>
            </div>
            <div :if={@operation.kind == :set_note}>
              <dt>New label</dt>
              <dd>{note_label(note_display(@operation))}</dd>
            </div>
            <div>
              <dt>Wallet</dt>
              <dd class="subject-wallet-mono">{short(@operation.signer)}</dd>
            </div>
            <div>
              <dt>Network</dt>
              <dd>Base</dd>
            </div>
          </dl>

          <p :if={@operation.kind == :stake} class="subject-wallet-share">{stake_timing()}</p>

          <%!-- What this transaction is about to divide. Once it settles, its own
                event says what really moved, so the estimate stops speaking. --%>
          <p
            :if={@operation.kind in [:pay, :sweep] && is_nil(@operation.terminal_at)}
            class="subject-wallet-share"
          >
            {share_copy(@operation)}
          </p>

          <p :if={@operation.kind == :sweep} class="subject-wallet-share">
            This pays the gas to move that balance on. Nothing is sent to your wallet, and another
            sweep before yours can make this fail.
          </p>

          <%!-- The list styling drops list semantics, so the role is stated. --%>
          <ol class="subject-wallet-steps" role="list" aria-label="Action progress">
            <li :for={step <- SubjectWalletActions.steps(@operation)} data-step={step["step"]}>
              <span>{step_label(step["step"], @operation)}</span>
              <span class="subject-wallet-step-state">{step_state(@operation, step["step"])}</span>
              <.transaction hash={SubjectWalletActions.step_hash(@operation, step["step"])} />
            </li>
          </ol>

          <p :if={@operation.state == :confirmed} class="subject-wallet-settled" role="status">
            {confirmed_copy(@operation)}
          </p>
          <p
            :if={@operation.state in [:reverted, :unverified]}
            class="subject-wallet-settled"
            role="alert"
          >
            {settled_copy(@operation.state)}
          </p>
          <p
            :if={@operation.state in [:not_sent, :cancelled, :expired, :submission_unknown]}
            class="subject-wallet-settled"
            role="status"
          >
            {settled_copy(@operation.state)}
          </p>

          <button
            :if={sendable?(@operation, @wallet)}
            type="button"
            data-subject-wallet-send={@operation.action_id}
            data-subject-wallet-signer={@operation.signer}
          >
            Confirm in wallet
          </button>
          <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
            This action belongs to another wallet. Switch back to it to finish.
          </p>
          <button
            :if={@operation.state == :submitted}
            type="button"
            phx-click="check_subject_wallet_step"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
          >
            Check again
          </button>
          <button
            :if={@operation.state == :prepared && !started?(@operation)}
            type="button"
            phx-click="cancel_subject_wallet_review"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
          >
            Cancel
          </button>
          <button
            :if={@operation.state in [:dispatched, :submitted]}
            type="button"
            phx-click="start_new_subject_wallet_action"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
          >
            Start something else
          </button>
          <button
            :if={@operation.terminal_at}
            type="button"
            phx-click="clear_subject_wallet_action"
            phx-target={@myself}
          >
            Do something else
          </button>
        </section>
      </div>
    </section>
    """
  end

  # The wallet Privy has selected, whenever it changes.
  @impl true
  def handle_event("subject_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("select_subject_action", %{"kind" => kind}, socket) do
    case action_kind(kind) do
      nil -> {:noreply, socket}
      kind -> {:noreply, assign(socket, kind: kind, amount: "", note: "", notice: nil)}
    end
  end

  def handle_event("subject_form_changed", params, socket) do
    {:noreply,
     assign(socket,
       amount: Map.get(params, "amount", socket.assigns.amount),
       note: Map.get(params, "note", socket.assigns.note),
       asset: Map.get(params, "asset", socket.assigns.asset),
       notice: nil
     )}
  end

  def handle_event("fill_subject_amount", _params, socket),
    do: {:noreply, assign(socket, amount: maximum(socket.assigns), notice: nil)}

  def handle_event("review_subject_action", params, socket) do
    {:noreply,
     socket.assigns.subject.subject_id
     |> Autolaunch.prepare_subject_wallet_action(
       socket.assigns.wallet,
       socket.assigns.kind,
       form_params(socket.assigns, params),
       opts(socket)
     )
     |> settled(socket)}
  end

  # The browser's preflight is necessary input, never authority: the locked
  # dispatch proves the account still holds this wallet, and only its winner is
  # handed the exact reviewed bytes.
  def handle_event("sign_subject_wallet_step", %{"action-id" => action_id}, socket) do
    socket.assigns.subject.subject_id
    |> Autolaunch.claim_subject_wallet_dispatch(action_id, socket.assigns.wallet, opts(socket))
    |> claimed(socket)
  end

  # The bound row goes on screen before Base is asked anything, so a read that
  # cannot answer leaves the transaction and its link exactly where they are.
  def handle_event(
        "subject_wallet_submitted",
        %{"action_id" => action_id, "step" => step, "transaction_hash" => hash},
        socket
      ) do
    case wallet_step(step) do
      nil -> {:noreply, socket}
      step -> submitted(socket, action_id, step, hash)
    end
  end

  def handle_event("check_subject_wallet_step", %{"action-id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject.subject_id
       |> Autolaunch.verify_subject_wallet_step(action_id, opts(socket))
       |> settled(socket)}

  # The exact EIP-1193 rejection of a claimed step: the wallet was asked and said
  # no, so nothing was broadcast and the action ends. Only that one code ends an
  # action; any other reported code is not a rejection and changes nothing.
  def handle_event(
        "subject_wallet_rejected",
        %{"action_id" => action_id, "code" => 4001},
        socket
      ),
      do:
        {:noreply,
         socket.assigns.subject.subject_id
         |> Autolaunch.close_subject_wallet_not_sent(action_id, opts(socket))
         |> settled(socket)}

  def handle_event("subject_wallet_rejected", _params, socket), do: {:noreply, socket}

  # The browser proved this claimed step never reached its wallet send, so the
  # same review becomes sendable again rather than ending.
  def handle_event("subject_wallet_dispatch_not_started", %{"action_id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject.subject_id
       |> Autolaunch.release_unstarted_subject_wallet_dispatch(action_id, opts(socket))
       |> settled(socket)}

  def handle_event("cancel_subject_wallet_review", %{"action-id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject.subject_id
       |> Autolaunch.cancel_subject_wallet_review(action_id, opts(socket))
       |> settled(socket)}

  def handle_event("start_new_subject_wallet_action", %{"action-id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject.subject_id
       |> Autolaunch.start_new_subject_wallet_action(action_id, opts(socket))
       |> settled(socket)}

  def handle_event("clear_subject_wallet_action", _params, socket),
    do:
      {:noreply,
       socket |> assign(operation: nil, amount: "", note: "") |> cleared() |> refreshed()}

  # Browser storage only prompts a restore; the owning account's row supplies
  # every fact. No row means the stored hint is stale, and saying so is what
  # stops it asking again on every reload.
  def handle_event("restore_subject_wallet_operation", _params, socket) do
    case Autolaunch.open_subject_wallet_operation(socket.assigns.subject.subject_id, opts(socket)) do
      {:ok, %{operation: nil}} -> {:noreply, cleared(socket)}
      result -> {:noreply, settled(result, socket)}
    end
  end

  def handle_event("subject_wallet_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

  attr :notice, :map, required: true

  defp notice(assigns) do
    ~H"""
    <p class="subject-wallet-notice" role={if @notice.tone == :error, do: "alert", else: "status"}>
      {@notice.message}
    </p>
    """
  end

  attr :hash, :string, default: nil

  defp transaction(assigns) do
    ~H"""
    <a
      :if={@hash}
      class="subject-wallet-mono"
      href={"https://basescan.org/tx/#{@hash}"}
      target="_blank"
      rel="noopener"
      aria-label="View this transaction on Basescan"
    >
      {short_hash(@hash)}
    </a>
    """
  end

  defp submitted(socket, action_id, step, hash) do
    subject_id = socket.assigns.subject.subject_id

    case Autolaunch.bind_subject_wallet_hash(subject_id, action_id, step, hash, opts(socket)) do
      {:ok, %{operation: bound}} = result ->
        socket = settled(result, socket)

        socket =
          subject_id
          |> Autolaunch.verify_subject_wallet_step(action_id, opts(socket))
          |> settled(socket)

        {:noreply, acknowledged(socket, bound, step)}

      refused ->
        {:noreply, settled(refused, socket)}
    end
  end

  # The closed sets this card maps a browser value through. Nothing here builds
  # an atom from what the browser sent: a value outside the set has no meaning
  # and is answered with nothing rather than with an error.
  defp action_kind("stake"), do: :stake
  defp action_kind("unstake"), do: :unstake
  defp action_kind("claim"), do: :claim
  defp action_kind("claim_all"), do: :claim_all
  defp action_kind("pay"), do: :pay
  defp action_kind("sweep"), do: :sweep
  defp action_kind("set_note"), do: :set_note
  defp action_kind(_unknown), do: nil

  defp wallet_step("approval"), do: :approval
  defp wallet_step("action"), do: :action
  defp wallet_step(_unknown), do: nil

  defp asset_key(id), do: Enum.find_value(@assets, &(&1.id == id && &1.key))

  defp settled({:ok, %{operation: operation}}, socket),
    do: socket |> assign(operation: operation, notice: nil) |> published()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  # Only the dispatch this claim just won may open a wallet, and it is read from
  # that claim's own result rather than from whatever this socket last held. A
  # refused or repeated claim therefore hands the browser nothing.
  defp claimed({:ok, %{operation: %{state: :dispatched} = operation}} = result, socket) do
    {:noreply,
     result
     |> settled(socket)
     |> push_event("autolaunch-subject-wallet:send", %{
       action_id: operation.action_id,
       step: Atom.to_string(operation.step)
     })}
  end

  defp claimed(result, socket), do: {:noreply, settled(result, socket)}

  # The one acknowledgement the browser waits for before it drops its own copy of
  # a reported hash: this exact hash is durable on this exact step.
  defp acknowledged(socket, operation, step),
    do:
      push_event(socket, "autolaunch-subject-wallet:hash-durable", %{
        action_id: operation.action_id,
        step: Atom.to_string(step),
        transaction_hash: SubjectWalletActions.step_hash(operation, step)
      })

  # The whole reviewed sequence, so the browser can check that what it is asked to
  # send really belongs to the operation it is holding.
  defp published(%{assigns: %{operation: nil}} = socket), do: cleared(socket)

  defp published(%{assigns: %{operation: operation}} = socket) do
    push_event(socket, "autolaunch-subject-wallet:operation", %{
      action_id: operation.action_id,
      subject_id: operation.subject_id,
      signer: operation.signer,
      chain_id: @chain_id,
      terminal: not is_nil(operation.terminal_at),
      steps: SubjectWalletActions.steps(operation)
    })
  end

  defp cleared(socket), do: push_event(socket, "autolaunch-subject-wallet:cleared", %{})

  # No Ethereum wallet selected — disconnected, unlinked, or Solana in front of
  # the customer. That is the ordinary empty state, not a refusal, and it reads
  # nothing and says nothing.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, state: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.subject_wallet_state(socket.assigns.subject.subject_id, address, opts(socket)) do
      {:ok, %{signer: signer} = state} -> switched(socket, signer, state)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # A review is prepared for one signer, so another wallet cannot spend it and it
  # is withdrawn. Anything already claimed stays exactly where it is, bound to the
  # wallet it was reviewed for.
  defp switched(%{assigns: %{wallet: wallet}} = socket, signer, state) when wallet != signer,
    do: socket |> assign(wallet: signer, state: state, notice: nil) |> withdraw() |> restored()

  defp switched(socket, signer, state),
    do: socket |> assign(wallet: signer, state: state, notice: nil) |> restored()

  # The account's open action for this subject is a server fact, so it is shown
  # whenever this wallet is adopted. Browser storage only ever prompts a replay
  # of a reported hash; a new tab, another device or cleared storage must still
  # see the action that is really in flight rather than a form that would refuse.
  defp restored(%{assigns: %{operation: nil}} = socket) do
    case Autolaunch.open_subject_wallet_operation(socket.assigns.subject.subject_id, opts(socket)) do
      {:ok, %{operation: nil}} -> socket
      {:ok, %{operation: _open}} = result -> settled(result, socket)
      _unavailable -> socket
    end
  end

  defp restored(socket), do: socket

  defp withdraw(%{assigns: %{operation: %{state: :prepared} = operation}} = socket) do
    if started?(operation), do: socket, else: cancel(socket, operation)
  end

  defp withdraw(socket), do: socket

  defp cancel(socket, operation) do
    case Autolaunch.cancel_subject_wallet_review(
           socket.assigns.subject.subject_id,
           operation.action_id,
           opts(socket)
         ) do
      {:ok, _cancelled} -> socket |> assign(operation: nil) |> cleared()
      denied -> settled(denied, socket)
    end
  end

  # Membership is a session fact and a balance is a chain fact. A wallet this
  # account does not hold is not adopted at all; one it does hold stays on screen
  # with the reason its state could not be read.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, state: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, state: nil, notice: notice(:info, reason))

  defp refreshed(%{assigns: %{wallet: nil}} = socket), do: socket
  defp refreshed(socket), do: adopt(socket, socket.assigns.wallet)

  defp opts(socket),
    do: [
      actor: actor(socket),
      context: %{session_lease: socket.assigns.session_lease}
    ]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp form_params(assigns, params) do
    %{
      "asset" => Map.get(params, "asset", assigns.asset),
      "amount" => Map.get(params, "amount", assigns.amount),
      "note" => Map.get(params, "note", assigns.note)
    }
  end

  # What Max means for the action in front of the customer, and nothing else.
  defp maximum(%{kind: :stake, state: state}), do: state.balances.subject
  defp maximum(%{kind: :unstake, state: state}), do: state.staked

  defp maximum(%{kind: :pay, asset: asset, state: state}),
    do: Map.get(state.balances, asset_key(asset), "")

  defp maximum(%{amount: amount}), do: amount

  defp ready?(%{kind: kind, amount: amount}) when kind in @amount_kinds, do: amount != ""
  defp ready?(_assigns), do: true

  defp amount_kind?(kind), do: kind in @amount_kinds
  defp asset_kind?(kind), do: kind in @asset_kinds
  defp receiver_kind?(kind), do: kind in @receiver_kinds

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  defp started?(operation),
    do:
      Enum.any?(
        SubjectWalletActions.steps(operation),
        &SubjectWalletActions.step_hash(operation, &1["step"])
      )

  # Where the sequence has got to, read from the operation's own step and state.
  defp step_state(%{step: step} = operation, step_name) do
    cond do
      Atom.to_string(step) == step_name -> current_state(operation.state)
      SubjectWalletActions.step_hash(operation, step_name) -> "Confirmed"
      true -> "Waiting"
    end
  end

  defp current_state(:prepared), do: "Ready"
  defp current_state(:dispatched), do: "In your wallet"
  defp current_state(:submitted), do: "Sent"
  defp current_state(:confirmed), do: "Confirmed"
  defp current_state(:reverted), do: "Reverted"
  defp current_state(:unverified), do: "Unresolved"
  defp current_state(:not_sent), do: "Not sent"
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"
  defp current_state(:submission_unknown), do: "Unresolved"

  defp step_label("approval", operation),
    do: "Allow #{argument(operation, "symbol")} to be spent"

  defp step_label("action", operation), do: verb(operation.kind)

  defp verb(kind), do: Enum.find(@actions, &(&1.kind == kind)).verb

  # The one thing a staker has to know about timing, said in the form before an
  # amount is chosen and again in the review that spends it.
  defp stake_timing,
    do: "Your stake counts straight away. You can take it back out from the next block onwards."

  # The one economic sentence a payment review owes the customer: the exact
  # amounts this inflow divides into as staking stands at review, never a share
  # or a rounded estimate. Stakers are paid for the stake they hold against the
  # whole SUBJECT supply, so their part stays small until much of that supply is
  # staked, and the treasury takes the remainder. The split is settled by the
  # contract when the payment is mined, so the sentence says which figures the
  # reviewed moment fixes and which it does not.
  defp share_copy(operation) do
    %{"gross" => gross, "skim" => skim, "net" => net} =
      allocation = argument(operation, "allocation")

    %{"stakers" => stakers, "treasury" => treasury} = allocation

    asset = operation |> argument("asset") |> asset_key()
    symbol = argument(operation, "symbol")
    shown = &"#{SubjectWalletActions.units(&1, asset)} #{symbol}"

    "Of this #{shown.(gross)}, #{shown.(skim)} goes to the protocol. As things stand right now, the remaining #{shown.(net)} divides into #{shown.(stakers)} for everyone staking SUBJECT on this subject and #{shown.(treasury)} for its treasury. If staking changes before this goes through, those last two amounts change with it."
  end

  defp confirmed_copy(%{kind: :claim_all, result: %{"claimed" => claimed}}) when claimed == %{},
    do: "Confirmed on Base. There was nothing available to claim."

  defp confirmed_copy(%{kind: :claim, result: %{"claimed" => claimed}}) when claimed == %{},
    do: "Confirmed on Base. There was nothing available to claim."

  defp confirmed_copy(%{kind: kind}) when kind in [:pay, :sweep],
    do: "Confirmed on Base. Your balances update once this subject's history is read back."

  defp confirmed_copy(_operation),
    do: "Confirmed on Base. Your balances update once this subject's history is read back."

  defp settled_copy(:reverted), do: "This transaction reverted on Base. Nothing moved."
  defp settled_copy(:unverified), do: "This transaction did not record the action you reviewed."
  defp settled_copy(:not_sent), do: "Your wallet declined this. Nothing was sent."
  defp settled_copy(:cancelled), do: "This review was cancelled. Nothing was sent."
  defp settled_copy(:expired), do: "This review expired before it was sent. Nothing was sent."

  defp settled_copy(:submission_unknown),
    do: "This one is still unresolved. Check your wallet activity before you try it again."

  # The browser reports a closed reason key as a string, never text of its own.
  # Only a key that proves the wallet was never asked to send may say nothing was
  # sent; everything else leaves the question open and says so.
  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you are using here, then try again. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do:
      "Your wallet may have sent this transaction. Check your wallet activity before you start another action."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  # The reviewed estimate is what the customer is shown, right up until this
  # action's own event proves what really moved. A stored result that carries no
  # amount leaves the review exactly as it was reviewed.
  defp amount_display(operation),
    do: SubjectWalletActions.verified_amount(operation) || argument(operation, "amount")

  defp note_display(operation),
    do: operation |> argument("note") |> Autolaunch.Chain.SubjectAbi.note_display()

  defp note_label(:cleared), do: "None"
  defp note_label({:address, address}), do: short(address)
  defp note_label({:text, text}), do: text
  defp note_label({:opaque, _bytes}), do: "Unreadable"

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
