defmodule AutolaunchWeb.StocksLaunchWalletComponent do
  @moduledoc """
  The wallet step of a Stocks launch: one review, then the one launch
  transaction. There is no launch fee.

  The wallet Privy has selected drives everything here and its address is proved
  against the mounted lease before any private fact is read. The browser reports
  a hash and stops; every outcome on screen is the server's own read of that hash.
  Press plumbing is `WalletPressComponent`, shared with the Agent launch.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.{Amounts, Lab, LaunchActions}
  alias Autolaunch.Stocks.LaunchOperation.Validations.ActiveLaunchLimit
  alias AutolaunchWeb.WalletPressComponent

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    stocks_unavailable: "Stock launches are not open on this site.",
    launches_paused: "New launches are paused right now.",
    active_stocks_launch_exists: ActiveLaunchLimit.message(),
    stock_not_admitted: "This stock token is not admitted for launches right now.",
    floor_price_too_low: "The floor price is too low to be used. Raise it on the draft.",
    floor_price_missing: "Enter a floor price on the draft.",
    required_raise_missing: "Enter a required raise on the draft.",
    required_raise_invalid:
      "The required raise must be more than zero, in an amount this stock token can represent. Check it on the draft.",
    amount_not_representable: "An amount has more decimal places than this stock token supports.",
    invalid_decimal: "An amount on the draft is not a plain decimal number.",
    price_out_of_range: "The floor price cannot be used. Check it on the draft.",
    launch_metadata_incomplete: "This draft is missing something the launch needs.",
    stock_invalid: "Choose a stock token on the draft.",
    unsupported_stock: "Choose a stock token on the draft.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now.",
    launch_step_moved: "This launch moved on while you were looking. Check it again.",
    submitted_hash_conflict: "This step already has a transaction.",
    submitted_step_mismatch: "That transaction is not the step this launch is waiting for.",
    launch_operation_not_found: "That launch is no longer open."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]

  @impl true
  # A press result may verify the launch, so the auction link follows it.
  def update(%{wallet_press_result: result, wallet_press_lease: lease}, socket) do
    socket = WalletPressComponent.consume(socket, lease, result)
    {:ok, adopt_operation(socket, socket.assigns.operation)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> WalletPressComponent.update_scope(assigns)
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:wallet_press_history, fn -> %{} end)
     |> assign_new(:operation, fn -> nil end)
     |> assign_new(:auction_path, fn -> nil end)
     |> assign_new(:active_stocks_launch, fn -> false end)}
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

      <p :if={@wallet && !@operation && @active_stocks_launch} class="launchpad-limit" role="status">
        {ActiveLaunchLimit.message()}
      </p>

      <div :if={@wallet && !@operation && !@active_stocks_launch} class="launch-wallet-open">
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
            <dt>Required raise</dt>
            <dd>
              {Amounts.grouped(argument(@operation, "required_stock_raised_units"))} {argument(
                @operation,
                "stock_symbol"
              )}. If bids fall short, every bid is refundable.
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
            <dt>Launch fee</dt>
            <dd>None</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@operation.signer)}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>{Autolaunch.Lab.network_name(@operation.envelope["chain_id"])}</dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>One transaction</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@operation.envelope["risk_copy"]}</p>

        <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
          <li :for={step <- LaunchActions.steps(@operation)} data-step={step["step"]}>
            <span>{step_label(step["step"])}</span>
            <span class="launch-wallet-step-state">{step_state(@operation, step["step"])}</span>
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
          <p>{verified_copy(@operation)}</p>
          <p>
            <.link :if={@auction_path} navigate={@auction_path}>Open the auction</.link>
            · Token <span class="launch-wallet-mono">{@operation.result["new_token"]}</span>
            · Auction <span class="launch-wallet-mono">{@operation.result["auction"]}</span>
          </p>
          <p>
            Bidding opens at block {@operation.result["start_block"]} and ends at block {@operation.result[
              "end_block"
            ]}.
          </p>
        </section>
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
      <WalletPressComponent.history
        :if={WalletPressComponent.scope(assigns)}
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
       WalletPressComponent.dispatch(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_report", params, socket),
    do:
      {:noreply,
       WalletPressComponent.report(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("wallet_press_verify", params, socket),
    do:
      {:noreply,
       WalletPressComponent.verify(socket, :stocks_launch, params, opts(socket), __MODULE__)}

  def handle_event("launch_active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("review_launch", _params, socket) do
    {:noreply,
     socket.assigns.draft.id
     |> LaunchActions.prepare(socket.assigns.wallet, opts(socket))
     |> settled(socket)}
  end

  def handle_event("cancel_launch_review", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> LaunchActions.cancel(opts(socket)) |> settled(socket)}

  def handle_event("start_new_launch", %{"action-id" => action_id}, socket),
    do: {:noreply, action_id |> LaunchActions.start_new(opts(socket)) |> settled(socket)}

  def handle_event("clear_launch", _params, socket),
    do: {:noreply, socket |> adopt_operation(nil) |> assign(notice: nil) |> cleared()}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  defp settled({:ok, %{operation: %{launch_draft_id: draft_id} = operation}}, socket) do
    if draft_id == socket.assigns.draft.id,
      do: socket |> adopt_operation(operation) |> assign(notice: nil) |> published(),
      else: socket |> adopt_operation(nil) |> assign(notice: nil) |> cleared()
  end

  defp settled({:ok, %{operation: nil}}, socket),
    do: socket |> adopt_operation(nil) |> cleared()

  defp settled({:error, error}, socket),
    do: assign(socket, notice: notice(:error, refusal(error)))

  defp published(%{assigns: %{operation: operation}} = socket) do
    send(self(), {:launch_review, :open})

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
      {:ok, %{signer: signer}} -> assign(socket, wallet: signer, notice: nil)
      {:error, error} -> refused(socket, address, refusal(error))
    end
  end

  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: address, notice: notice(:info, reason))

  # A verified launch links to the auction row its verification projected, found
  # by the chain and address the chain reported.
  defp adopt_operation(socket, %{state: :chain_verified, result: %{"auction" => address}} = op) do
    {:ok, auction} =
      Autolaunch.get_auction_by_chain_address(Lab.chain_id(), address, actor: actor(socket))

    assign(socket, operation: op, auction_path: auction && "/auctions/#{auction.id}")
  end

  defp adopt_operation(socket, operation),
    do: assign(socket, operation: operation, auction_path: nil)

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

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

  defp step_label("launch"), do: "Create the launch"

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

  defp verified_copy(%{envelope: %{"chain_id" => chain_id}}) do
    if Autolaunch.Lab.test_chain?(chain_id),
      do:
        "The test transaction and launch record were verified. Test assets have no mainnet value.",
      else:
        "Your transaction and launch record were verified. This launch will appear here when its onchain record is ready."
  end

  defp settled_copy(%{state: :cancelled}), do: WalletPressComponent.withdrawal_copy()

  defp settled_copy(%{state: :expired}),
    do: "This review expired before the launch was sent. Nothing was sent."

  defp settled_copy(%{state: :invalidated, reason: reason, envelope: %{"chain_id" => chain_id}}),
    do: invalidated_copy(Autolaunch.Lab.test_chain?(chain_id)) <> " Review it again: #{reason}."

  defp invalidated_copy(true),
    do: "The fork changed before the launch was sent. Nothing was sent."

  defp invalidated_copy(false), do: "Base moved on before the launch was sent. Nothing was sent."

  defp exact_values(operation) do
    [
      {"Launchpad", argument(operation, "launchpad")},
      {"Stock token", argument(operation, "stock")},
      {"Stock decimals", argument(operation, "stock_decimals")},
      {"Required raise (stock base units)", argument(operation, "required_stock_raised")},
      {"Floor price (every digit)",
       "#{argument(operation, "floor_price_executable")} #{argument(operation, "stock_symbol")} per token"},
      {"Floor price (Q96)", argument(operation, "floor_price_q96")},
      {"Bid tick spacing (Q96)", argument(operation, "tick_spacing_q96")},
      {"Bidding opens (blocks after creation)", argument(operation, "start_lead_blocks")},
      {"Auction length (blocks)", argument(operation, "auction_duration_blocks")},
      {"Reviewed block",
       "#{argument(operation, "block_number")} · #{argument(operation, "block_hash")}"},
      {"Calldata digest", operation.envelope["metadata"]["calldata_sha256"]}
    ]
  end

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
    if Autolaunch.Lab.test_chain?(),
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

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
