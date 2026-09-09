defmodule AutolaunchWeb.StocksLaunchWalletComponent do
  @moduledoc """
  The wallet step of a Stocks launch: one review, one transaction.

  The wallet Privy has selected drives everything here and its address is proved
  against the mounted lease before any private fact is read. The browser reports
  a hash and stops; every outcome on screen is the server's own read of that hash.
  Press plumbing is `WalletPressComponent`, shared with the Agent launch.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.{Amounts, LaunchActions}
  alias AutolaunchWeb.WalletPressComponent

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch back to a wallet on this account to continue.",
    invalid_address: "Switch back to a wallet on this account to continue.",
    chain_unavailable:
      "The local lab could not be read just now. Check that it is still running.",
    stocks_unavailable: "Stock launches are not open on this site.",
    launches_paused: "New launches are paused right now.",
    stock_not_admitted: "This stock token is not admitted for launches right now.",
    subject_splitter_unrecognised:
      "The subject revenue address is not a recognised Agent revenue address. Check it on the draft.",
    start_too_soon: "The start must be at least 10 minutes from now. Move it later on the draft.",
    start_too_late: "The start must be within 30 days. Move it earlier on the draft.",
    start_missing: "Choose a start date and time on the draft.",
    floor_price_too_low: "The floor price is too low to be used. Raise it on the draft.",
    floor_price_missing: "Enter a floor price on the draft.",
    minimum_raise_missing: "Enter a minimum raise on the draft.",
    minimum_raise_unrepresentable:
      "The minimum raise has more decimal places than this stock token supports.",
    amount_not_representable: "An amount has more decimal places than this stock token supports.",
    invalid_decimal: "An amount on the draft is not a plain decimal number.",
    price_out_of_range: "The floor price cannot be used. Check it on the draft.",
    launch_metadata_incomplete: "This draft is missing something the launch needs.",
    stock_invalid: "Choose a stock token on the draft.",
    unsupported_stock: "Choose a stock token on the draft.",
    fee_administrator_invalid: "The fee administrator is not a usable address.",
    subject_splitter_invalid: "The subject revenue address is not a usable address.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now.",
    launch_step_moved: "This launch moved on while you were looking. Check it again.",
    submitted_hash_conflict: "This step already has a transaction.",
    launch_operation_not_found: "That launch is no longer open."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket),
    do: {:ok, WalletPressComponent.consume(socket, lease, result)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="launch-wallet"
      data-wallet-scope={WalletPressComponent.scope(assigns)}
      phx-hook="AutolaunchLaunchWallet"
      phx-target={@myself}
    >
      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <div :if={!@wallet} class="launch-wallet-empty">
        <p>Choose the wallet you want to launch from.</p>
        <Regent.Primitives.button type="button" data-launch-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div :if={@wallet && !@operation} class="launch-wallet-open">
        <p class="launch-wallet-hint">
          Launching from {short(@wallet)}. One transaction; your wallet confirms it.
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
        :if={@operation && WalletPressComponent.scope(assigns)}
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
            <dt>Auction currency</dt>
            <dd>
              {argument(@operation, "stock_symbol")}
              <span class="launch-wallet-mono">{argument(@operation, "stock")}</span>
            </dd>
          </div>
          <div>
            <dt>Bidding opens</dt>
            <dd>
              {zoned(argument(@operation, "start_at"), argument(@operation, "start_timezone"))} · block {argument(
                @operation,
                "start_block"
              )}
            </dd>
          </div>
          <div>
            <dt>Estimated close</dt>
            <dd>
              {zoned(argument(@operation, "estimated_end_at"), argument(@operation, "start_timezone"))} · block {argument(
                @operation,
                "end_block"
              )}
            </dd>
          </div>
          <div>
            <dt>Minimum raise</dt>
            <dd>{argument(@operation, "minimum_raise")} {argument(@operation, "stock_symbol")}</dd>
          </div>
          <div>
            <dt>Floor price</dt>
            <dd>
              {Amounts.compact_decimal(argument(@operation, "floor_price_executable"))} {argument(
                @operation,
                "stock_symbol"
              )} per token
              <span :if={argument(@operation, "floor_price_adjusted")}>
                (rounded down from {argument(@operation, "floor_price_entered")})
              </span>
            </dd>
          </div>
          <div>
            <dt>Subject revenue</dt>
            <dd :if={argument(@operation, "subject_enabled")} class="launch-wallet-mono">
              On · {argument(@operation, "subject_splitter")}
            </dd>
            <dd :if={!argument(@operation, "subject_enabled")}>Off</dd>
          </div>
          <div>
            <dt>Fee administrator</dt>
            <dd class="launch-wallet-mono">{argument(@operation, "fee_administrator")}</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@operation.signer)}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>Local Base fork · chain 31337</dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>One transaction, no fee</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@operation.envelope["risk_copy"]}</p>

        <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
          <li :for={step <- LaunchActions.steps(@operation)} data-step={step["step"]}>
            <span>Create the launch</span>
            <span class="launch-wallet-step-state">{current_state(@operation.state)}</span>
            <span
              :if={LaunchActions.step_hash(@operation, step["step"])}
              class="launch-wallet-mono"
              data-local-transaction-hash
            >
              {short_hash(LaunchActions.step_hash(@operation, step["step"]))}
            </span>
          </li>
        </ol>

        <section :if={@operation.state == :chain_verified} class="launch-wallet-settled" role="status">
          <p>
            The local test transaction and launch record were verified. Test assets have no mainnet value.
          </p>
          <p>
            <.link navigate={"/auctions/#{Autolaunch.LabProjection.auction_id(@operation.result["auction"])}"}>
              Open the auction
            </.link>
            · Token <span class="launch-wallet-mono">{@operation.result["new_token"]}</span>
            · Auction <span class="launch-wallet-mono">{@operation.result["auction"]}</span>
          </p>
        </section>
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
      <WalletPressComponent.history
        :if={WalletPressComponent.scope(assigns)}
        history={@wallet_press_history}
        target={@myself}
      />
    </section>
    """
  end

  @impl true
  def handle_event("wallet_press_dispatch", params, socket),
    do:
      {:noreply,
       WalletPressComponent.dispatch(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       WalletPressComponent.report(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       WalletPressComponent.verify(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_restore", params, socket),
    do: {:noreply, WalletPressComponent.restore(socket, :stocks_launch, params, opts(socket))}

  def handle_event("launch_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("review_launch", _params, socket) do
    {:noreply,
     socket.assigns.draft.id
     |> LaunchActions.prepare(socket.assigns.wallet, opts(socket))
     |> settled(socket)}
  end

  def handle_event("launch_submitted", params, socket) do
    {:noreply,
     WalletPressComponent.legacy_report(
       socket,
       :stocks_launch,
       params,
       opts(socket),
       __MODULE__,
       "autolaunch-launch:hash-durable"
     )}
  end

  def handle_event("check_launch_step", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> LaunchActions.verify(opts(socket)) |> settled(socket)}

  def handle_event("cancel_launch_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> LaunchActions.cancel(opts(socket)) |> settled(socket)}

  def handle_event("start_new_launch", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> LaunchActions.start_new(opts(socket)) |> settled(socket)}

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> assign(operation: nil, notice: nil) |> cleared()}

  def handle_event("restore_launch_operation", _params, socket) do
    case LaunchActions.open_operation(opts(socket)) do
      {:ok, %{operation: nil}} -> {:noreply, cleared(socket)}
      result -> {:noreply, settled(result, socket)}
    end
  end

  def handle_event("launch_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  defp settled({:ok, %{operation: %{launch_draft_id: draft_id} = operation}}, socket) do
    if draft_id == socket.assigns.draft.id,
      do: socket |> assign(operation: operation, notice: nil) |> published(),
      else: socket |> assign(operation: nil, notice: nil) |> cleared()
  end

  defp settled({:ok, %{operation: nil}}, socket),
    do: socket |> assign(operation: nil) |> cleared()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  defp published(%{assigns: %{operation: operation}} = socket) do
    addressed(socket, "autolaunch-launch:operation", %{
      action_id: operation.action_id,
      signer: operation.signer,
      chain_id: operation.envelope["chain_id"],
      lab: operation.envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: operation.envelope["arguments"]["block_number"],
        block_hash: operation.envelope["arguments"]["block_hash"]
      },
      terminal: not is_nil(operation.terminal_at),
      steps: LaunchActions.steps(operation)
    })
  end

  defp cleared(socket), do: addressed(socket, "autolaunch-launch:cleared", %{})

  defp addressed(socket, event, payload) do
    push_event(
      socket,
      event,
      payload |> Map.put(:card, socket.assigns.id) |> Map.put(:component_id, socket.assigns.id)
    )
  end

  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(socket, address) do
    case LaunchActions.wallet_state(address, opts(socket)) do
      {:ok, %{signer: signer}} -> socket |> assign(wallet: signer, notice: nil) |> restored()
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  defp restored(%{assigns: %{operation: nil}} = socket) do
    case LaunchActions.open_operation(opts(socket)) do
      {:ok, %{operation: %{}}} = result -> settled(result, socket)
      _none -> socket
    end
  end

  defp restored(socket), do: socket

  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, notice: notice(:info, reason))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp sendable?(%{state: state, signer: signer, terminal_at: nil}, wallet)
       when state in [:prepared, :dispatched, :submitted],
       do: signer == wallet

  defp sendable?(_operation, _wallet), do: false

  defp started?(operation), do: not is_nil(LaunchActions.step_hash(operation, :launch))

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

  defp settled_copy(%{state: :reverted}),
    do: "This local test transaction reverted. Nothing was created."

  defp settled_copy(%{state: :unverified}),
    do: "This transaction did not record the launch you reviewed."

  defp settled_copy(%{state: :submission_unknown}),
    do: "This one is still unresolved. Check your wallet activity before you try it again."

  defp settled_copy(%{state: :not_sent}), do: "Your wallet declined this. Nothing was sent."
  defp settled_copy(%{state: :cancelled}), do: WalletPressComponent.withdrawal_copy()

  defp settled_copy(%{state: :expired}),
    do: "This review expired before the launch was sent. Nothing was sent."

  defp settled_copy(%{state: :invalidated, reason: reason}),
    do:
      "The local lab changed before the launch was sent. Nothing was sent. Review it again: #{reason}."

  defp exact_values(operation) do
    [
      {"Launchpad", argument(operation, "launchpad")},
      {"Stock token", argument(operation, "stock")},
      {"Stock decimals", argument(operation, "stock_decimals")},
      {"Start block", argument(operation, "start_block")},
      {"End block", argument(operation, "end_block")},
      {"Floor price (every digit)",
       "#{argument(operation, "floor_price_executable")} #{argument(operation, "stock_symbol")} per token"},
      {"Floor price (Q96)", argument(operation, "floor_price_q96")},
      {"Bid tick spacing (Q96)", argument(operation, "tick_spacing_q96")},
      {"Required raise (base units)", argument(operation, "required_stock_raised")},
      {"Fee administrator", argument(operation, "fee_administrator")},
      {"Subject splitter", argument(operation, "subject_splitter")},
      {"Reviewed block",
       "#{argument(operation, "block_number")} · #{argument(operation, "block_hash")}"},
      {"Calldata digest", operation.envelope["metadata"]["calldata_sha256"]}
    ]
  end

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you are using here, then try again. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do:
      "Your wallet may have sent this transaction. Check your wallet activity before you start another launch."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  @doc false
  def zoned(iso, zone) when is_binary(iso) and is_binary(zone) do
    with {:ok, utc, _offset} <- DateTime.from_iso8601(iso),
         {:ok, local} <- DateTime.shift_zone(utc, zone) do
      Calendar.strftime(local, "%Y-%m-%d %H:%M") <> " " <> zone
    else
      _unreadable -> iso
    end
  end

  def zoned(iso, _zone), do: iso

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
