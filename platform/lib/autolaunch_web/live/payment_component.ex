defmodule AutolaunchWeb.PaymentComponent do
  @moduledoc """
  The Make a payment card on a graduated Base Revstake token's page: pay USDC,
  REGENT or the token into its revenue split through the launch's payment
  receiver, or route a balance already waiting there. Built like the staking
  card: a panel over the card walks the wallet through each reviewed step and
  closes itself when the chain confirms it.

  The `launch` assign names the launch (`%{chain: :base, auction: record}`)
  and `pool` is its current facts. Nothing pending is stored. The figures are
  public reads; the review lives on this page only, the browser reports a hash
  and stops, and every outcome on screen is the server's own read of that
  hash. The recent payments below the card are confirmed chain records.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.StakeComponent
  alias Phoenix.LiveView.JS

  @recheck_ms 2_000
  @recheck_limit 90
  @history_ms 3_000
  @history_limit 20

  @copy %{
    authentication_required: "Sign in to use your wallet here.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    invalid_chain_response: "Base gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    stake_unavailable: "Payments are not open on this token yet.",
    unsupported_asset: "Choose one of the listed assets.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount using this asset's decimal places.",
    invalid_decimal: "Enter an amount using this asset's decimal places.",
    amount_not_representable: "Enter an amount using this asset's decimal places.",
    amount_too_large: "That amount is too large to pay at once.",
    amount_above_balance: "That is more than this wallet holds.",
    nothing_to_sweep: "There is nothing waiting at the payment address right now.",
    envelope_invalid: "This review is out of date. Close it and review again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity.",
    payment_not_routed:
      "That transaction did not make this payment. Check your wallet activity, then close this and review again."
  }
  @generic "That did not go through. Try again in a moment."
  @steps %{"token_approval" => :token_approval, "pay" => :pay, "sweep" => :sweep}
  @kinds %{"pay" => :pay, "sweep" => :sweep}
  @assets ~w(usdc regent token)

  @impl true
  def update(assigns, socket) do
    scope =
      {assigns.launch.auction.id, assigns.current_human_id, assigns.session_lease}

    socket =
      if socket.assigns[:scope] == scope do
        socket
      else
        assign(socket,
          scope: scope,
          asset: "usdc",
          amount: "",
          error: nil,
          wallet: nil,
          payments: :reading,
          history: [],
          watching: nil,
          notice: nil,
          review: nil,
          sent: %{},
          done: nil,
          revision: Map.get(socket.assigns, :revision, -1) + 1
        )
      end

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:authenticated, fn -> false end)
      |> assign_new(:current_human_id, fn -> nil end)
      |> assign_new(:session_lease, fn -> nil end)

    # A pool read at a new block carries new balances, so the card's own are
    # read again beside it, with the confirmed payments.
    if socket.assigns[:pool_block] == assigns.pool.block,
      do: {:ok, socket},
      else: {:ok, socket |> assign(pool_block: assigns.pool.block) |> read() |> histories()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap token-stake"
      phx-hook="AutolaunchReviewedSteps"
      phx-target={@myself}
      phx-mounted={JS.ignore_attributes(["data-awaiting-wallet"])}
      aria-labelledby={@id <> "-title"}
    >
      <.payment_done :if={@done} id={"#{@id}-done"} done={@done} target={@myself} />

      <h2 id={@id <> "-title"} class="token-stake__title">Make a payment</h2>
      <p class="token-stake__lead">
        Pay into {@pool.token.symbol}'s revenue split. Part goes to everyone staking {@pool.token.symbol} and the rest to its treasury. Your wallet confirms every step.
      </p>

      <Regent.Primitives.button
        :if={action(assigns) == :sign_in}
        type="button"
        class="token-swap__submit"
        data-account-target="sign-in"
      >
        Sign in to pay
      </Regent.Primitives.button>

      <div :if={action(assigns) == :connect_wallet} class="token-stake">
        <p class="token-stake__lead">Choose the wallet you want to pay from.</p>
        <Regent.Primitives.button type="button" class="token-swap__submit" data-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div :if={action(assigns) == :act} class="token-swap__stack">
        <form
          id={"#{@id}-form-#{@revision}"}
          class="token-swap__form token-stake__form"
          aria-label={"Pay into #{@pool.token.symbol}'s revenue split"}
          phx-change={"form-#{@revision}"}
          phx-submit="review"
          phx-target={@myself}
          inert={!is_nil(@review)}
        >
          <dl class="token-stake__facts">
            <div>
              <dt>Wallet</dt>
              <dd class="autolaunch-exact-value">{short(@wallet)}</dd>
            </div>
            <div :for={asset <- assets(@pool)}>
              <dt>{asset.symbol}</dt>
              <dd>{balance(@payments, asset.id)}</dd>
            </div>
          </dl>

          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <label for={@id <> "-asset"}>Asset</label>
            </div>
            <select id={@id <> "-asset"} name="asset">
              <option :for={asset <- assets(@pool)} value={asset.id} selected={asset.id == @asset}>
                {asset.symbol}
              </option>
            </select>
          </div>

          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <label for={@id <> "-amount"}>Amount</label>
              <div class="token-swap__portions" role="group" aria-label="Your whole balance">
                <button type="button" phx-click="fill" phx-target={@myself}>Max</button>
              </div>
            </div>
            <div class="token-swap__amount-row">
              <input
                id={@id <> "-amount"}
                name="amount"
                type="text"
                value={@amount}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
                aria-label={"Amount of #{symbol(@pool, @asset)}"}
                aria-invalid={to_string(!is_nil(@error))}
                phx-debounce="300"
              />
              <span class="token-swap__currency" title={symbol(@pool, @asset)}>
                <span>{symbol(@pool, @asset)}</span>
              </span>
            </div>
            <p class="token-swap__leg-foot">
              <span>Payment address {short(@pool.fees.receiver)}</span>
            </p>
          </div>

          <Regent.Primitives.button
            type="submit"
            name="kind"
            value="pay"
            class="token-swap__submit"
          >
            Review payment
          </Regent.Primitives.button>

          <p class="token-stake__lead">
            Waiting at the payment address: {waiting(@payments, @asset)} {symbol(@pool, @asset)}. Anyone can route it into the revenue split. You pay only the network fee, and nothing is sent to your wallet.
          </p>
          <Regent.Primitives.button
            type="submit"
            name="kind"
            value="sweep"
            variant="secondary"
            class="token-swap__submit"
          >
            Route waiting {symbol(@pool, @asset)}
          </Regent.Primitives.button>

          <p :if={@error || (is_nil(@review) && @notice)} class="token-swap__error" role="alert">
            {@error || @notice}
          </p>
        </form>

        <StakeComponent.stake_review
          :if={@review}
          id={"#{@id}-review"}
          title={title(@review.kind)}
          facts={@review.review}
          notes={@review.notes}
          steps={steps(@review, @sent)}
          next_step={next_step(@review, @sent)}
          stalled={stalled(@sent)}
          notice={@notice}
          target={@myself}
        />
      </div>

      <section :if={@history != []} aria-labelledby={@id <> "-history"}>
        <h3 id={@id <> "-history"} class="token-stake__title">Recent payments</h3>
        <dl class="token-stake__facts">
          <div :for={payment <- @history}>
            <dt>
              <time datetime={DateTime.to_iso8601(payment.occurred_at)}>
                {Calendar.strftime(payment.occurred_at, "%b %-d, %H:%M UTC")}
              </time>
              · {from(payment)}
            </dt>
            <dd>{Decimal.to_string(payment.gross, :normal)} {payment.token_symbol}</dd>
          </div>
        </dl>
      </section>
    </section>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("form-" <> revision, params, socket) do
    if revision == Integer.to_string(socket.assigns.revision),
      do: {:noreply, entered(socket, params)},
      else: {:noreply, socket}
  end

  def handle_event("fill", _params, socket) do
    case held(socket.assigns.payments, socket.assigns.asset) do
      %{balance: balance} when is_binary(balance) ->
        {:noreply,
         assign(socket,
           amount: balance,
           error: nil,
           notice: nil,
           revision: socket.assigns.revision + 1
         )}

      _unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("review", %{"kind" => name} = params, socket) when is_map_key(@kinds, name) do
    socket = entered(socket, params)

    request = %{
      kind: Map.fetch!(@kinds, name),
      launch: socket.assigns.launch,
      asset: socket.assigns.asset,
      amount: socket.assigns.amount
    }

    case StakeActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(review: review, sent: %{}, notice: nil, done: nil)
         |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: copy(refusal(error)))}
    end
  end

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, checked(socket, name, hash, 0)}

  def handle_event("check_step", %{"step" => name}, socket) do
    case socket.assigns.sent[name] do
      %{hash: hash} -> {:noreply, checked(socket, name, hash, 0)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do:
      {:noreply,
       assign(socket, notice: StakeComponent.wallet_failure_copy(reason, socket.assigns.review))}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Reads run off the page's own process, and an answer for a wallet, a block
  # or a sent step the page has since left is dropped.
  @impl true
  def handle_async(:payments, {:ok, {wallet, block, read}}, socket) do
    if wallet == socket.assigns.wallet and block == socket.assigns.pool.block,
      do: {:noreply, assign(socket, payments: payments(read))},
      else: {:noreply, socket}
  end

  def handle_async({:recheck, name}, {:ok, {hash, attempts, read}}, socket) do
    case socket.assigns.sent[name] do
      %{hash: ^hash} -> {:noreply, read(socket, name, hash, attempts, read)}
      _left -> {:noreply, socket}
    end
  end

  def handle_async(:history, {:ok, {attempts, {:ok, history}}}, socket),
    do: {:noreply, socket |> assign(history: history) |> watched(attempts)}

  def handle_async(_read, _unavailable, socket), do: {:noreply, socket}

  defp entered(socket, params) do
    amount = params |> Map.get("amount", socket.assigns.amount) |> limited()
    asset = Map.get(params, "asset", socket.assigns.asset)

    error =
      if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
        do: nil,
        else: "Enter an amount using digits and a decimal point."

    assign(socket,
      amount: amount,
      asset: if(asset in @assets, do: asset, else: socket.assigns.asset),
      error: error,
      notice: nil
    )
  end

  defp limited(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp limited(_value), do: ""

  defp read(%{assigns: %{pool: pool, wallet: wallet}} = socket) do
    socket
    |> assign(payments: :reading)
    |> start_async(:payments, fn -> {wallet, pool.block, StakeActions.payments(pool, wallet)} end)
  end

  defp payments({:ok, %{assets: assets}}), do: Map.new(assets, &{&1.id, &1})
  defp payments({:error, _reason}), do: :unreadable

  defp held(payments, asset) when is_map(payments), do: Map.get(payments, asset)
  defp held(_payments, _asset), do: nil

  # The confirmed payments, read again every few seconds after this card's
  # own payment until the history carries its transaction.
  defp histories(socket, attempts \\ 0) do
    id = socket.assigns.launch.auction.id
    delay = if attempts == 0, do: 0, else: @history_ms

    start_async(socket, :history, fn ->
      Process.sleep(delay)
      {attempts, Autolaunch.recent_revenue_payments(id)}
    end)
  end

  defp watched(%{assigns: %{watching: nil}} = socket, _attempts), do: socket

  defp watched(%{assigns: %{watching: hash, history: history}} = socket, attempts) do
    if Enum.any?(history, &(&1.transaction_hash == hash)) or attempts >= @history_limit,
      do: assign(socket, watching: nil),
      else: histories(socket, attempts + 1)
  end

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash, attempts) do
    read = StakeActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket))
    read(socket, name, hash, attempts, read)
  end

  defp checked(socket, _name, _hash, _attempts), do: socket

  defp read(socket, name, hash, attempts, {:ok, %{outcome: :confirmed} = confirmed}) do
    sent =
      Map.put(socket.assigns.sent, name, sent(hash, :confirmed, attempts, confirmed[:result]))

    if last_step?(socket.assigns.review, name),
      do: finished(socket, sent, hash),
      else: assign(socket, sent: sent, notice: nil)
  end

  defp read(socket, name, hash, attempts, {:ok, %{outcome: outcome}}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, name, sent(hash, outcome, attempts, nil)),
      notice: if(outcome == :reverted, do: reverted_copy(socket.assigns.review.kind))
    )
    |> rechecked(name)
  end

  # A confirmed transaction that did not make this payment is an answer, not
  # a read to retry: the panel says so and the step stays open.
  defp read(socket, name, hash, attempts, {:error, error}) do
    case refusal(error) do
      :payment_not_routed ->
        assign(socket,
          sent: Map.put(socket.assigns.sent, name, sent(hash, :reverted, attempts, nil)),
          notice: copy(:payment_not_routed)
        )

      reason ->
        socket
        |> assign(
          sent: Map.put(socket.assigns.sent, name, sent(hash, :pending, attempts, nil)),
          notice: if(attempts == 0, do: copy(reason))
        )
        |> rechecked(name)
    end
  end

  defp sent(hash, outcome, attempts, result),
    do: %{hash: hash, outcome: outcome, attempts: attempts, result: result}

  defp last_step?(%{steps: steps}, name), do: List.last(steps)["step"] == name

  # Every balance on the card moved, so the page reads the pool again, the
  # card's balances follow from that read, and the history is watched until
  # it carries this payment.
  defp finished(socket, sent, hash) do
    %{"step" => name} = List.last(socket.assigns.review.steps)
    send(self(), :reload_pool)

    socket
    |> assign(amount: "", notice: nil, done: sent[name].result, watching: hash)
    |> closed()
    |> histories(1)
  end

  defp rechecked(%{assigns: %{review: %{envelope: envelope}}} = socket, name) do
    case socket.assigns.sent[name] do
      %{outcome: :pending, hash: hash, attempts: attempts} when attempts < @recheck_limit ->
        step = Map.fetch!(@steps, name)
        opts = opts(socket)

        start_async(socket, {:recheck, name}, fn ->
          Process.sleep(@recheck_ms)
          {hash, attempts + 1, StakeActions.verify(envelope, step, hash, opts)}
        end)

      _settled ->
        socket
    end
  end

  defp closed(socket) do
    socket
    |> assign(review: nil, sent: %{}, revision: socket.assigns.revision + 1)
    |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

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

  # The wallet is only what the browser reports; every review proves it
  # against the session again. A review belongs to the wallet it was made for.
  defp adopt(socket, nil), do: socket |> assign(wallet: nil) |> reviewed_for_wallet() |> read()

  defp adopt(socket, address) when is_binary(address),
    do:
      socket
      |> assign(wallet: String.downcase(address))
      |> reviewed_for_wallet()
      |> read()

  defp adopt(socket, _other), do: socket

  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet, do: socket, else: closed(socket)
  end

  defp reviewed_for_wallet(socket), do: socket

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp action(%{authenticated: false}), do: :sign_in
  defp action(%{wallet: nil}), do: :connect_wallet
  defp action(_assigns), do: :act

  defp assets(pool), do: StakeActions.payment_assets(pool)

  defp symbol(pool, id), do: Enum.find_value(assets(pool), &(&1.id == id && &1.symbol))

  defp balance(:reading, _asset), do: "Reading…"
  defp balance(:unreadable, _asset), do: "Not readable right now"
  defp balance(payments, asset), do: payments |> Map.fetch!(asset) |> Map.fetch!(:balance)

  defp waiting(:reading, _asset), do: "Reading…"
  defp waiting(:unreadable, _asset), do: "Not readable right now"
  defp waiting(payments, asset), do: payments |> Map.fetch!(asset) |> Map.fetch!(:waiting)

  defp from(%{payer: nil}), do: "routed from the waiting balance"
  defp from(%{payer: payer}), do: "from " <> short(payer)

  defp steps(review, sent) do
    Enum.map(review.steps, fn %{"step" => name} ->
      %{name: name, label: step_label(name, review), state: step_state(sent[name])}
    end)
  end

  # One button at a time: the first step the wallet has not sent yet, or one
  # that did not go through. A sent step moves the button on at once; nothing
  # waits for the network before the next press can reach the wallet.
  defp next_step(review, sent) do
    Enum.find(steps(review, sent), &(&1.state in [:ready, :reverted]))
  end

  defp stalled(sent) do
    for {name, %{outcome: :pending, attempts: attempts}} <- sent,
        attempts >= @recheck_limit,
        do: name
  end

  defp step_label("token_approval", review),
    do: "Allow #{review.envelope["arguments"]["asset_symbol"]} to be spent"

  defp step_label("pay", _review), do: "Pay"
  defp step_label("sweep", _review), do: "Route the waiting balance"

  defp step_state(nil), do: :ready
  defp step_state(%{outcome: :pending}), do: :sent
  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted

  defp title(:pay), do: "Pay"
  defp title(:sweep), do: "Route the waiting balance"

  defp reverted_copy(:pay),
    do: "The payment did not go through and nothing moved. Close this and review again."

  defp reverted_copy(:sweep),
    do:
      "Nothing moved. Someone else may have routed that balance first. Close this and review again."

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  attr :id, :string, required: true
  attr :done, :map, required: true
  attr :target, :any, required: true

  defp payment_done(assigns) do
    ~H"""
    <aside id={@id} class="token-swap__toast" role="status">
      <div>
        <strong>{if @done["kind"] == "pay", do: "Payment made", else: "Waiting balance routed"}</strong>
        <p>
          {@done["gross_units"]} {@done["asset_symbol"]} went into the revenue split.
        </p>
      </div>
      <Regent.Primitives.button
        type="button"
        variant="quiet"
        phx-click="dismiss_done"
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <StakeComponent.cross size="18" />
      </Regent.Primitives.button>
    </aside>
    """
  end
end
