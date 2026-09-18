defmodule AutolaunchWeb.SwapComponent do
  @moduledoc """
  The trade form shared by the token page and the listing dialogs: an amount, a
  live quote, a price-protection option, then one review and the wallet steps
  it names.

  Nothing is stored. The quote is a public read; the review lives on this page
  only, the browser reports a hash and stops, and every outcome on screen is
  the server's own read of that hash.
  """
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.SwapForm

  alias Autolaunch.Actors.Human
  alias Autolaunch.SwapActions

  @default_protection "1"

  @copy %{
    authentication_required: "Sign in to trade from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address: "Connect the wallet you signed in with, then review the trade again.",
    chain_unavailable: "The pool could not be read just now. Try again in a moment.",
    invalid_chain_response: "The pool gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    lab_contract_missing: "Trading is not available for this token yet.",
    swap_unavailable: "Trading is not available for this token yet.",
    quote_unavailable: "The pool cannot fill this amount right now. Try a smaller amount.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this token supports.",
    amount_too_large: "That amount is too large to trade at once.",
    amount_above_balance: "This wallet holds less than that.",
    protection_out_of_range: "Price protection is a number from 1 to 10.",
    envelope_invalid: "This review is out of date. Review the trade again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required]
  @steps %{
    "token_approval" => :token_approval,
    "permit2_approval" => :permit2_approval,
    "swap" => :swap
  }

  @impl true
  def update(assigns, socket) do
    auction = assigns.token.auction

    scope =
      {assigns.token.id, auction.kind, auction.chain_id, auction.quote_token_address,
       auction.quote_token_symbol}

    socket =
      if socket.assigns[:scope] == scope do
        socket
      else
        assign(socket,
          scope: scope,
          direction: :buy,
          amount: "",
          error: nil,
          estimate: nil,
          protection: @default_protection,
          protection_error: nil,
          options_open: false,
          wallet: nil,
          notice: nil,
          review: nil,
          sent: %{},
          revision: Map.get(socket.assigns, :revision, -1) + 1
        )
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:authenticated, fn -> false end)
     |> assign_new(:current_human_id, fn -> nil end)
     |> assign_new(:session_lease, fn -> nil end)
     |> assign(
       token_view: Autolaunch.Token.presentation(assigns.token),
       entry_symbol: entry_symbol(auction),
       read_only?: Autolaunch.Prelaunch.read_only?()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="AutolaunchReviewedSteps" phx-target={@myself}>
      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <.swap_form
        :if={@entry_symbol && !@review}
        id={"#{@id}-form-#{@revision}"}
        sell_symbol={sell(assigns)}
        buy_symbol={buy(assigns)}
        sell_image={if @direction == :sell, do: @token_view.image}
        buy_image={if @direction == :buy, do: @token_view.image}
        amount={@amount}
        estimated_output={@estimate}
        error={@error}
        protection={@protection}
        protection_error={@protection_error}
        options_open={@options_open}
        options_event="toggle_options"
        action_label="Review trade"
        action_enabled={!@read_only?}
        disabled_reason={if @read_only?, do: "Trading opens after launch."}
        change_event={"form-#{@revision}"}
        submit_event="review_trade"
        reverse_event="reverse"
        target={@myself}
      />

      <p :if={@entry_symbol && !@review && !@authenticated} class="bid-empty">
        <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-in">
          Sign in to trade
        </Regent.Primitives.button>
      </p>
      <p :if={@entry_symbol && !@review && @authenticated && !@wallet} class="bid-empty">
        <Regent.Primitives.button type="button" variant="secondary" data-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </p>

      <section
        :if={@review}
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label="Trade review"
      >
        <h3>Review this trade</h3>
        <dl>
          <div :for={[label, value] <- @review.review}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@review.envelope["expected_signer"])}</dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>{step_count(@review.steps)}</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@review.envelope["risk_copy"]}</p>

        <ol class="launch-wallet-steps" role="list" aria-label="Trade progress">
          <li :for={step <- @review.steps} data-step={step["step"]}>
            <span>{step_label(step["step"], @review)}</span>
            <span class="launch-wallet-step-state">{step_state(@sent[step["step"]])}</span>
            <span :if={@sent[step["step"]]} class="launch-wallet-mono" data-local-transaction-hash>
              {short_hash(@sent[step["step"]].hash)}
            </span>
          </li>
        </ol>

        <p :if={traded(@sent)} class="launch-wallet-settled" role="status">
          Trade complete. You received {traded(@sent)["received_units"]} {traded(@sent)[
            "buy_symbol"
          ]}.
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
            :if={next_step(@review.steps, @sent)}
            type="button"
            data-reviewed-step={next_step(@review.steps, @sent)}
          >
            {step_label(next_step(@review.steps, @sent), @review)}
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
            {if traded(@sent), do: "Done", else: "Start over"}
          </Regent.Primitives.button>
        </div>
      </section>

      <p :if={!@entry_symbol} class="token-swap__notice" role="status">
        Trading is not available for this token yet.
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("form-" <> revision, params, socket) do
    if revision == Integer.to_string(socket.assigns.revision),
      do: {:noreply, socket |> entered(params) |> estimated()},
      else: {:noreply, socket}
  end

  def handle_event("toggle_options", _params, socket),
    do: {:noreply, assign(socket, options_open: !socket.assigns.options_open)}

  def handle_event("reverse", _params, socket) do
    {:noreply,
     assign(socket,
       direction: if(socket.assigns.direction == :buy, do: :sell, else: :buy),
       amount: "",
       error: nil,
       estimate: nil,
       notice: nil,
       revision: socket.assigns.revision + 1
     )}
  end

  def handle_event("review_trade", params, socket) do
    socket = entered(socket, params)

    request = %{
      auction: socket.assigns.token.auction,
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      protection: socket.assigns.protection
    }

    case SwapActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply, socket |> assign(review: review, sent: %{}, notice: nil) |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: notice(:error, refusal(error)))}
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

  # "Start over" keeps the entered amount to adjust; a finished trade starts a fresh form.
  def handle_event("clear_review", _params, socket) do
    {:noreply,
     socket
     |> assign(if traded(socket.assigns.sent), do: [amount: "", estimate: nil], else: [])
     |> assign(review: nil, sent: %{}, notice: nil, revision: socket.assigns.revision + 1)
     |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # The quote is read off the page's own process, and an answer for an amount or
  # direction the form has since left is dropped.
  @impl true
  def handle_async(:estimate, {:ok, {asked, result}}, socket) do
    if asked == asked(socket) do
      case result do
        {:ok, estimate} -> {:noreply, assign(socket, estimate: estimate)}
        {:error, _unavailable} -> {:noreply, assign(socket, estimate: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:estimate, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, estimate: nil)}

  defp entered(socket, params) do
    amount = params |> Map.get("amount", socket.assigns.amount) |> limited()
    protection = params |> Map.get("protection", socket.assigns.protection) |> limited()

    error =
      if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
        do: nil,
        else: "Enter an amount using digits and a decimal point."

    socket
    |> assign(amount: amount, error: error)
    |> protected(String.trim(protection))
  end

  defp limited(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp limited(_value), do: ""

  # A usable setting is shown the way it will be applied: rounded to two places.
  defp protected(socket, typed) do
    case SwapActions.protection(typed) do
      {:ok, bps} ->
        assign(socket,
          protection: SwapActions.protection_percent(bps),
          protection_error: nil
        )

      {:error, _out_of_range} ->
        assign(socket,
          protection: typed,
          protection_error: @copy.protection_out_of_range,
          options_open: true
        )
    end
  end

  defp estimated(%{assigns: %{error: nil, amount: amount}} = socket) when amount != "" do
    asked = asked(socket)
    request = %{auction: socket.assigns.token.auction, direction: asked.direction, amount: amount}

    socket
    |> assign(estimate: nil)
    |> start_async(:estimate, fn -> {asked, SwapActions.estimate(request)} end)
  end

  defp estimated(socket), do: assign(socket, estimate: nil)

  defp asked(socket),
    do: %{
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      revision: socket.assigns.revision
    }

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    case SwapActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket)) do
      {:ok, %{outcome: outcome} = read} ->
        entry = %{hash: hash, outcome: outcome, result: Map.get(read, :result)}

        assign(socket,
          sent: Map.put(socket.assigns.sent, name, entry),
          notice: outcome_notice(outcome)
        )

      {:error, error} ->
        assign(socket, notice: notice(:error, refusal(error)))
    end
  end

  defp checked(socket, _name, _hash), do: socket

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

  # The wallet is only what the browser reports; every read that matters proves
  # it against the session again. A review belongs to the wallet it was made for.
  defp adopt(socket, nil), do: assign(socket, wallet: nil) |> reviewed_for_wallet()

  defp adopt(socket, address) when is_binary(address),
    do: assign(socket, wallet: String.downcase(address)) |> reviewed_for_wallet()

  defp adopt(socket, _other), do: socket

  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet,
      do: socket,
      else:
        socket
        |> assign(review: nil, sent: %{})
        |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp reviewed_for_wallet(socket), do: socket

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp sell(%{direction: :buy, entry_symbol: symbol}), do: symbol
  defp sell(%{token_view: %{symbol: symbol}}), do: symbol
  defp buy(%{direction: :buy, token_view: %{symbol: symbol}}), do: symbol
  defp buy(%{entry_symbol: symbol}), do: symbol

  defp traded(sent) do
    case sent["swap"] do
      %{outcome: :confirmed, result: result} -> result
      _other -> nil
    end
  end

  # One button at a time: the first step the wallet has not sent yet, or one
  # that reverted. A sent step moves the button on at once; nothing waits for
  # the network before the next press can reach the wallet.
  defp next_step(steps, sent) do
    Enum.find_value(steps, fn %{"step" => name} ->
      if match?(%{outcome: outcome} when outcome in [:pending, :confirmed], sent[name]),
        do: nil,
        else: name
    end)
  end

  defp step_count([_one]), do: "One transaction"
  defp step_count([_one, _two]), do: "Two transactions"
  defp step_count([_one, _two, _three]), do: "Three transactions"

  defp step_label("token_approval", review),
    do: "Allow #{review.envelope["arguments"]["sell_symbol"]} to be used for trades"

  defp step_label("permit2_approval", review),
    do: "Allow this trade to spend your #{review.envelope["arguments"]["sell_symbol"]}"

  defp step_label("swap", _review), do: "Trade"

  defp step_state(nil), do: "Ready"
  defp step_state(%{outcome: :pending}), do: "Sent"
  defp step_state(%{outcome: :confirmed}), do: "Verified"
  defp step_state(%{outcome: :reverted}), do: "Reverted"

  defp outcome_notice(:pending),
    do: %{tone: :info, message: "Sent. Waiting for the network to include it."}

  defp outcome_notice(:confirmed), do: nil

  defp outcome_notice(:reverted),
    do: %{
      tone: :error,
      message:
        "That transaction reverted. Nothing was traded by it. If the price moved, review the trade again."
    }

  defp exact_values(review) do
    arguments = review.envelope["arguments"]

    [
      {"Pool", arguments["pool_id"]},
      {"Router", arguments["router"]},
      {"You pay (base units)", arguments["amount_in_atomic"]},
      {"Quote (base units)", arguments["quote_atomic"]},
      {"Lowest accepted (base units)", arguments["min_out_atomic"]},
      {"Deadline (Unix seconds)", arguments["deadline"]},
      {"Reviewed block", "#{arguments["block_number"]} · #{arguments["block_hash"]}"},
      {"Calldata digest", review.envelope["metadata"]["calldata_sha256"]}
    ]
  end

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under this test network's number. Point that network at the test network in your wallet's settings, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason) when reason in @unheld,
    do: %{tone: tone, message: Map.fetch!(@copy, reason)}

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"

  defp entry_symbol(%{kind: :agent, chain_id: chain_id, quote_token_symbol: "REGENT"}) do
    if base_chain?(chain_id), do: "REGENT"
  end

  defp entry_symbol(%{
         kind: :stocks,
         chain_id: chain_id,
         quote_token_address: address,
         quote_token_symbol: symbol
       })
       when is_binary(address) and address != "" and is_binary(symbol) do
    if base_chain?(chain_id) and String.trim(symbol) != "", do: symbol
  end

  defp entry_symbol(_auction), do: nil

  defp base_chain?(chain_id), do: chain_id in [8453, Autolaunch.Lab.chain_id()]
end
