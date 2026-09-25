defmodule AutolaunchWeb.SubjectWalletComponent do
  @moduledoc """
  The Make a payment card on a Revstake token's page: pay into the token's
  revenue split, or route a balance already waiting at its payment address.
  Staking and claiming live in the token page's own staking card.

  The wallet the customer signed in with drives everything here, read from the
  mounted lease, so its balances show as soon as the card mounts. A press opens
  that wallet, or Privy's connect step when this tab has not connected it, and a
  note names both wallets while the browser is on another one.

  The browser reports a hash and stops. Every outcome on screen comes from the
  server's own read of that exact hash. Each distinct press is independent;
  recovery reports prior outcomes and never sends again automatically.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch
  alias Autolaunch.Actors.Human
  alias Autolaunch.SubjectWalletActions
  alias AutolaunchWeb.SignedInWallet

  @chain_id 8453

  @assets [
    %{id: "usdc", key: :usdc},
    %{id: "regent", key: :regent},
    %{id: "subject", key: :subject}
  ]

  @copy %{
    authentication_required: "Sign in to use your wallet here.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "You are now signed in with a different wallet. Reload the page to continue.",
    invalid_address:
      "You are now signed in with a different wallet. Reload the page to continue.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    subject_not_found: "Payments are not open on this token yet.",
    subject_unavailable: "This token could not be read just now.",
    subject_not_on_base: "This token is not on Base.",
    subject_token_unavailable: "Payments are not open on this token yet.",
    subject_splitter_unavailable: "This token is not sharing revenue yet.",
    subject_treasury_unavailable: "This token has no treasury yet.",
    canonical_receiver_unavailable: "This token has no payment address yet.",
    receiver_not_canonical: "This payment address is not the launch's own. Nothing was prepared.",
    splitter_subject_mismatch: "This token's revenue split does not match it.",
    splitter_usdc_mismatch: "This token's revenue split does not match it.",
    splitter_regent_mismatch: "This token's revenue split does not match it.",
    splitter_treasury_mismatch: "This token's revenue split does not match its treasury.",
    receiver_splitter_mismatch: "This payment address does not belong to this token.",
    receiver_subject_mismatch: "This payment address does not belong to this token.",
    receiver_usdc_mismatch: "This payment address does not belong to this token.",
    receiver_regent_mismatch: "This payment address does not belong to this token.",
    receiver_treasury_mismatch: "This payment address does not belong to this token.",
    subject_wallet_preparation_unavailable: "Payments are not open on this token yet.",
    amount_above_balance: "That is more than this wallet holds.",
    nothing_to_sweep: "There is nothing waiting at the payment address right now.",
    invalid_amount: "Enter an amount using this asset's decimal places.",
    unsupported_asset: "Choose one of the listed assets.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this payment is waiting for.",
    subject_wallet_operation_not_found: "That payment is no longer open."
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
     |> assign_new(:state, fn -> nil end)
     |> assign_new(:asset, fn -> "usdc" end)
     |> assign_new(:amount, fn -> "" end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign(assets: @assets)
     |> SignedInWallet.adopt(&adopt/2)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="subject-wallet rg-panel rg-panel--surface"
      data-wallet-scope={AutolaunchWeb.WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchSubjectWallet"
      phx-target={@myself}
      aria-labelledby={@id <> "-title"}
    >
      <header class="subject-wallet-heading">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id={@id <> "-title"}>Make a payment</h2>
        </Regent.Structure.section_bar>
        <p>
          Pay into {@symbol}'s revenue split. Part goes to everyone staking {@symbol} and the rest
          to its treasury. Your wallet confirms every step.
        </p>
      </header>

      <.notice :if={@notice} notice={@notice} />

      <p :if={!@authenticated} class="subject-wallet-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          Sign in to pay
        </Regent.Primitives.button>
      </p>

      <div :if={@authenticated && @wallet && @state} class="subject-wallet-body">
        <dl :if={!@operation} class="subject-wallet-balances">
          <div>
            <dt>Wallet</dt>
            <dd class="subject-wallet-mono">{short(@wallet)}</dd>
          </div>
          <div :for={asset <- @assets}>
            <dt>{asset_label(asset.key, @symbol)}</dt>
            <dd>{@state.balances[asset.key]}</dd>
          </div>
        </dl>

        <form
          :if={!@operation}
          id={"#{@id}-form"}
          class="subject-wallet-choose"
          phx-change="subject_form_changed"
          phx-submit="review_subject_action"
          phx-target={@myself}
        >
          <div class="subject-wallet-field rg-field">
            <label for={"#{@id}-asset"}>Asset</label>
            <select id={"#{@id}-asset"} name="asset">
              <option :for={asset <- @assets} value={asset.id} selected={asset.id == @asset}>
                {asset_label(asset.key, @symbol)}
              </option>
            </select>
          </div>

          <div class="subject-wallet-field rg-field">
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
              <Regent.Primitives.button
                type="button"
                phx-click="fill_subject_amount"
                phx-target={@myself}
                variant="secondary"
              >
                Max
              </Regent.Primitives.button>
            </div>
          </div>

          <p :if={@state.receiver} class="subject-wallet-hint">
            Payment address {short(@state.receiver.address)}
          </p>

          <Regent.Primitives.button
            class="subject-wallet-primary"
            type="submit"
            name="kind"
            value="pay"
            disabled={@amount == ""}
          >
            Review payment
          </Regent.Primitives.button>

          <div :if={@state.receiver} class="subject-wallet-waiting">
            <p class="subject-wallet-hint">
              Waiting at the payment address: {waiting(@state.receiver, @asset)} {asset_label(
                asset_key(@asset),
                @symbol
              )}. Anyone can route it into the revenue split. You pay only the network fee, and
              nothing is sent to your wallet.
            </p>
            <Regent.Primitives.button type="submit" name="kind" value="sweep" variant="secondary">
              Route waiting {asset_label(asset_key(@asset), @symbol)}
            </Regent.Primitives.button>
          </div>
        </form>

        <section
          :if={@operation}
          id={"#{@id}-review"}
          class="subject-wallet-review"
          aria-label="Payment review"
        >
          <h3>{title(@operation.kind)}</h3>
          <dl>
            <div :if={amount_display(@operation)}>
              <dt>Amount</dt>
              <dd>{amount_display(@operation)} {operation_symbol(@operation, @symbol)}</dd>
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

          <%!-- What this transaction is about to divide. Once it settles, its own
                event says what really moved, so the estimate stops speaking. --%>
          <p :if={is_nil(@operation.terminal_at)} class="subject-wallet-share">
            {share_copy(@operation, @symbol)}
          </p>

          <p :if={@operation.kind == :sweep} class="subject-wallet-share">
            This pays the network fee to move that balance on. Nothing is sent to your wallet, and
            someone else routing it first can make this fail.
          </p>

          <%!-- The list styling drops list semantics, so the role is stated. --%>
          <ol class="subject-wallet-steps" role="list" aria-label="Payment progress">
            <li :for={step <- SubjectWalletActions.steps(@operation)} data-step={step["step"]}>
              <span>{step_label(step["step"], @operation, @symbol)}</span>
              <span class="subject-wallet-step-state">{step_state(@operation, step["step"])}</span>
              <.transaction hash={SubjectWalletActions.step_hash(@operation, step["step"])} />
            </li>
          </ol>

          <p :if={@operation.state == :confirmed} class="subject-wallet-settled" role="status">
            Confirmed on Base. Balances update once the payment is read back.
          </p>
          <p
            :if={@operation.state in [:cancelled, :expired]}
            class="subject-wallet-settled"
            role="status"
          >
            {settled_copy(@operation.state)}
          </p>

          <SignedInWallet.note
            :if={sendable?(@operation, @wallet)}
            signed_in={@wallet}
            browser={@browser_wallets}
          />
          <Regent.Primitives.button
            :if={sendable?(@operation, @wallet)}
            type="button"
            data-subject-wallet-send={@operation.action_id}
            data-wallet-step={@operation.step}
            data-subject-wallet-signer={@operation.signer}
          >
            Confirm in wallet
          </Regent.Primitives.button>
          <p :if={@operation.signer != @wallet && is_nil(@operation.terminal_at)} role="status">
            This payment belongs to another wallet. Sign in with that wallet to finish.
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
            phx-click="cancel_subject_wallet_review"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Cancel
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.state in [:dispatched, :submitted]}
            type="button"
            phx-click="start_new_subject_wallet_action"
            phx-value-action-id={@operation.action_id}
            phx-target={@myself}
            variant="secondary"
          >
            Start another payment
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@operation.terminal_at}
            type="button"
            phx-click="clear_subject_wallet_action"
            phx-target={@myself}
            variant="secondary"
          >
            Make another payment
          </Regent.Primitives.button>
        </section>
      </div>
      <AutolaunchWeb.WalletPressComponent.history
        :if={AutolaunchWeb.WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
        label={&step_label(&1, &2, @symbol)}
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
         :subject,
         params,
         opts(socket),
         __MODULE__
       )}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.report(
         socket,
         :subject,
         params,
         opts(socket),
         __MODULE__
       )}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       AutolaunchWeb.WalletPressComponent.verify(
         socket,
         :subject,
         params,
         opts(socket),
         __MODULE__
       )}

  # The wallets this tab has connected, whenever they change: only for the note.
  def handle_event("browser_wallets", params, socket),
    do: {:noreply, assign(socket, browser_wallets: SignedInWallet.reported(params))}

  def handle_event("subject_form_changed", params, socket) do
    {:noreply,
     assign(socket,
       amount: Map.get(params, "amount", socket.assigns.amount),
       asset: Map.get(params, "asset", socket.assigns.asset),
       notice: nil
     )}
  end

  def handle_event("fill_subject_amount", _params, socket),
    do: {:noreply, assign(socket, amount: maximum(socket.assigns), notice: nil)}

  def handle_event("review_subject_action", params, socket) do
    case action_kind(params["kind"]) do
      nil ->
        {:noreply, socket}

      kind ->
        {:noreply,
         socket.assigns.subject_id
         |> Autolaunch.prepare_subject_wallet_action(
           socket.assigns.wallet,
           kind,
           form_params(socket.assigns, params),
           opts(socket)
         )
         |> settled(socket)}
    end
  end

  def handle_event("cancel_subject_wallet_review", %{"action-id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject_id
       |> Autolaunch.cancel_subject_wallet_review(action_id, opts(socket))
       |> settled(socket)}

  def handle_event("start_new_subject_wallet_action", %{"action-id" => action_id}, socket),
    do:
      {:noreply,
       socket.assigns.subject_id
       |> Autolaunch.start_new_subject_wallet_action(action_id, opts(socket))
       |> settled(socket)}

  def handle_event("clear_subject_wallet_action", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, amount: "") |> cleared() |> refreshed()}

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

  # The closed set this card maps a browser value through. Nothing here builds
  # an atom from what the browser sent: a value outside the set has no meaning
  # and is answered with nothing rather than with an error.
  defp action_kind("pay"), do: :pay
  defp action_kind("sweep"), do: :sweep
  defp action_kind(_unknown), do: nil

  defp asset_key(id), do: Enum.find_value(@assets, &(&1.id == id && &1.key))

  defp asset_label(:subject, symbol), do: symbol
  defp asset_label(:usdc, _symbol), do: "USDC"
  defp asset_label(:regent, _symbol), do: "REGENT"

  defp operation_symbol(operation, symbol),
    do: operation |> argument("asset") |> asset_key() |> asset_label(symbol)

  defp settled({:ok, %{operation: operation}}, socket),
    do: socket |> assign(operation: operation, notice: nil) |> published()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  # The whole reviewed sequence, so the browser can check that what it is asked to
  # send really belongs to the operation it is holding.
  defp published(%{assigns: %{operation: nil}} = socket), do: cleared(socket)

  defp published(%{assigns: %{operation: operation}} = socket) do
    push_event(socket, "autolaunch-subject-wallet:operation", %{
      component_id: socket.assigns.id,
      action_id: operation.action_id,
      subject_id: operation.subject_id,
      signer: operation.signer,
      chain_id: @chain_id,
      terminal: not is_nil(operation.terminal_at),
      steps: SubjectWalletActions.steps(operation)
    })
  end

  defp cleared(socket), do: push_event(socket, "autolaunch-subject-wallet:cleared", %{})

  # Signed out: the card reads nothing and says nothing.
  defp adopt(socket, nil), do: assign(socket, wallet: nil, state: nil, notice: nil)

  defp adopt(socket, address) do
    case Autolaunch.subject_wallet_state(socket.assigns.subject_id, address, opts(socket)) do
      {:ok, %{signer: signer} = state} -> switched(socket, signer, state)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  # A review is prepared for one signer, so after signing in with another
  # wallet it cannot be spent and it is withdrawn. Anything already claimed stays exactly where it is, bound to the
  # wallet it was reviewed for.
  defp switched(%{assigns: %{wallet: wallet}} = socket, signer, state) when wallet != signer,
    do: socket |> assign(wallet: signer, state: state, notice: nil) |> withdraw()

  defp switched(socket, signer, state),
    do: assign(socket, wallet: signer, state: state, notice: nil)

  defp withdraw(%{assigns: %{operation: %{state: :prepared} = operation}} = socket) do
    if started?(operation), do: socket, else: cancel(socket, operation)
  end

  defp withdraw(socket), do: socket

  defp cancel(socket, operation) do
    case Autolaunch.cancel_subject_wallet_review(
           socket.assigns.subject_id,
           operation.action_id,
           opts(socket)
         ) do
      {:ok, _cancelled} -> socket |> assign(operation: nil) |> cleared()
      denied -> settled(denied, socket)
    end
  end

  # Membership is a session fact and a balance is a chain fact. A wallet the
  # session no longer vouches for is not adopted at all; the signed-in one stays
  # on screen with the reason its state could not be read.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, state: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do:
      assign(socket,
        wallet: address,
        state: nil,
        notice: notice(:info, reason),
        signed_in_for: nil
      )

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
      "amount" => Map.get(params, "amount", assigns.amount)
    }
  end

  defp maximum(%{asset: asset, state: state}), do: Map.get(state.balances, asset_key(asset), "")

  defp waiting(receiver, asset), do: Map.get(receiver.balances, asset_key(asset))

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
  defp current_state(:cancelled), do: "Cancelled"
  defp current_state(:expired), do: "Expired"

  defp step_label("approval", operation, symbol),
    do: "Allow #{operation_symbol(operation, symbol)} to be spent"

  defp step_label("action", operation, _symbol), do: title(operation.kind)

  defp title(:pay), do: "Pay"
  defp title(:sweep), do: "Route the waiting balance"

  # The one economic sentence a payment review owes the customer: the exact
  # amounts this inflow divides into as staking stands at review, never a share
  # or a rounded estimate. Stakers are paid for the stake they hold against the
  # whole token supply, so their part stays small until much of that supply is
  # staked, and the treasury takes the remainder. The split is settled by the
  # contract when the payment is mined, so the sentence says which figures the
  # reviewed moment fixes and which it does not.
  defp share_copy(operation, symbol) do
    %{"gross" => gross, "skim" => skim, "net" => net} =
      allocation = argument(operation, "allocation")

    %{"stakers" => stakers, "treasury" => treasury} = allocation

    asset = operation |> argument("asset") |> asset_key()
    shown = &"#{SubjectWalletActions.units(&1, asset)} #{asset_label(asset, symbol)}"

    "Of this #{shown.(gross)}, #{shown.(skim)} goes to the protocol. As things stand right now, the remaining #{shown.(net)} divides into #{shown.(stakers)} for everyone staking #{symbol} and #{shown.(treasury)} for its treasury. If staking changes before this goes through, those last two amounts change with it."
  end

  defp settled_copy(:cancelled), do: AutolaunchWeb.WalletPressComponent.withdrawal_copy()
  defp settled_copy(:expired), do: "This review expired before it was sent. Nothing was sent."

  # The press whose transaction the card is waiting on: the submitted attempt of
  # the current step, whose hash the chain has not answered about yet.
  defp submitted_press(operation),
    do:
      Enum.find_value(
        operation.attempts,
        &(&1.state == :submitted and &1.step == operation.step and &1.id)
      )

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  # The reviewed estimate is what the customer is shown, right up until this
  # payment's own event proves what really moved.
  defp amount_display(operation),
    do: SubjectWalletActions.verified_amount(operation) || argument(operation, "amount")

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
