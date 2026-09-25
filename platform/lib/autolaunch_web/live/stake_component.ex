defmodule AutolaunchWeb.StakeComponent do
  @moduledoc """
  The staking card of a graduated launch, on its Base or Robinhood token page:
  what the launch's staking contract holds, what this wallet has in it, an
  amount to stake or unstake, and the open actions (claim, collect the locked
  liquidity's trading fees, and for a memestock launch settle for stakers; a
  Revstake launch's swap fee reaches its splitter on the trade itself). A
  panel over the card walks the wallet through each reviewed action and
  closes itself when the chain confirms it.

  The `launch` assign names the launch: `%{chain: :base, auction: record}` or
  `%{chain: :robinhood, auction: address}`; `pool` is its current facts.

  The wallet is the one the customer signed in with, read from the mounted
  lease. A press opens that wallet, or Privy's connect step when this tab has
  not connected it, and a note names both wallets while the browser is on
  another one.

  Nothing is stored. The figures are public reads; the review lives on this
  page only, the browser reports a hash and stops, and every outcome on
  screen is the server's own read of that hash.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.Components.ShareDialog
  alias AutolaunchWeb.SignedInWallet
  alias Phoenix.LiveView.JS

  @recheck_ms 2_000
  @recheck_limit 90

  @copy %{
    authentication_required: "Sign in to stake from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "You are now signed in with a different wallet. Reload the page to continue.",
    invalid_address: "Connect the wallet you signed in with, then try again.",
    chain_unavailable: "The staking contract could not be read just now. Try again in a moment.",
    invalid_chain_response:
      "The staking contract gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    stake_unavailable: "Staking is not available for this token yet.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this token supports.",
    amount_too_large: "That amount is too large to move at once.",
    amount_above_balance: "This wallet holds less than that.",
    amount_above_stake: "You have less than that staked.",
    envelope_invalid: "This review is out of date. Close it and review again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }
  @generic "That did not go through. Try again in a moment."
  @steps %{
    "token_approval" => :token_approval,
    "stake" => :stake,
    "unstake" => :unstake,
    "claim" => :claim,
    "settle" => :settle,
    "collect_full_range" => :collect_full_range,
    "collect_stock_only" => :collect_stock_only
  }
  @kinds %{
    "stake" => :stake,
    "unstake" => :unstake,
    "claim" => :claim,
    "settle" => :settle,
    "collect" => :collect
  }

  @impl true
  def update(assigns, socket) do
    scope =
      {assigns.launch.chain, launch_key(assigns.launch), assigns.current_human_id,
       assigns.session_lease}

    socket =
      if socket.assigns[:scope] == scope do
        socket
      else
        assign(socket,
          scope: scope,
          amount: limited(Map.get(assigns, :initial_amount, "")),
          error: nil,
          wallet: nil,
          signed_in_for: nil,
          position: nil,
          read_for: nil,
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
      |> assign_new(:share_url, fn -> nil end)
      |> assign_new(:share_image, fn -> nil end)
      |> assign_new(:browser_wallets, fn -> [] end)
      |> assign(read_only?: Autolaunch.Prelaunch.read_only?())
      |> SignedInWallet.adopt(&adopt/2)

    # A pool read at a new block carries new figures, and another wallet has
    # figures of its own, so the wallet's are read again beside them.
    read_for = {assigns.pool.block, socket.assigns.wallet}

    if socket.assigns[:read_for] == read_for,
      do: {:ok, socket},
      else: {:ok, socket |> assign(read_for: read_for) |> positioned()}
  end

  defp launch_key(%{chain: :base, auction: %{id: id}}), do: id
  defp launch_key(%{chain: :robinhood, auction: address}), do: address

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap token-stake"
      data-stake-panel
      phx-hook="AutolaunchReviewedSteps"
      phx-target={@myself}
      phx-mounted={JS.ignore_attributes(["data-awaiting-wallet"])}
      aria-labelledby={@id <> "-title"}
    >
      <.stake_done
        :if={@done}
        id={"#{@id}-done"}
        done={@done}
        share={share(assigns)}
        dismiss_event="dismiss_done"
        target={@myself}
      />

      <h2 id={@id <> "-title"} class="token-stake__title">
        {stake_name(@pool)} {@pool.token.symbol}
      </h2>
      <p class="token-stake__lead">
        Tokens are not locked. You can unstake at any time after the block in which you staked.
      </p>
      <p :if={@wallet} class="autolaunch-exact-value">Staking wallet: {@wallet}</p>
      <details>
        <summary>How rewards work</summary>
        <p>{lead(@pool)}</p>
      </details>

      <dl class="token-stake__facts">
        <div>
          <dt>Staked by everyone</dt>
          <dd>{@pool.fees.splitter.total_staked} {@pool.token.symbol}</dd>
        </div>
        <div :if={@pool.kind == :stocks}>
          <dt>Waiting for stakers</dt>
          <dd>{@pool.fees.stakers.accrued} {@pool.currency.symbol}</dd>
        </div>
        <div :for={position <- @pool.positions}>
          <dt>{position.label} fees to collect</dt>
          <dd>{uncollected(position.uncollected, @pool)}</dd>
        </div>
        <div :if={@position}>
          <dt>Your stake</dt>
          <dd>{@position.staked.shown} {@pool.token.symbol}</dd>
        </div>
        <div :if={@position}>
          <dt>You can claim</dt>
          <dd>{claimable(@position.claimable, @pool)}</dd>
        </div>
      </dl>

      <div class="token-swap__stack">
        <form
          id={"#{@id}-form-#{@revision}"}
          class="token-swap__form token-stake__form"
          aria-label={"Stake or unstake #{@pool.token.symbol}"}
          phx-change={"form-#{@revision}"}
          phx-submit="review"
          phx-target={@myself}
          inert={!is_nil(@review)}
        >
          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <label for={@id <> "-amount"}>Amount</label>
              <div
                :if={@position}
                class="token-swap__portions"
                role="group"
                aria-label="Part of your balance"
              >
                <button
                  :for={{label, percent} <- [{"25%", 25}, {"50%", 50}, {"75%", 75}, {"Max", 100}]}
                  type="button"
                  phx-click="fill"
                  phx-value-percent={percent}
                  phx-target={@myself}
                >
                  {label}
                </button>
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
                aria-label={"Amount of #{@pool.token.symbol}"}
                aria-invalid={to_string(!is_nil(@error))}
                phx-debounce="300"
              />
              <span class="token-swap__currency" title={@pool.token.symbol}>
                <span>{@pool.token.symbol}</span>
              </span>
            </div>
            <p class="token-swap__leg-foot">
              <span :if={@position}>
                {@position.balance.shown} {@pool.token.symbol} in your wallet
              </span>
            </p>
          </div>

          <div :if={action(assigns) == :act && @position} class="token-stake__actions">
            <Regent.Primitives.button
              type="button"
              variant="secondary"
              phx-click="review_all"
              phx-value-kind="stake"
              phx-target={@myself}
            >
              {stake_name(@pool)} all
            </Regent.Primitives.button>
            <Regent.Primitives.button
              type="button"
              variant="secondary"
              phx-click="review_all"
              phx-value-kind="unstake"
              phx-target={@myself}
            >
              Unstake all
            </Regent.Primitives.button>
          </div>
          <div :if={action(assigns) == :act} class="token-stake__actions">
            <Regent.Primitives.button
              type="submit"
              name="kind"
              value="stake"
              class="token-swap__submit"
            >
              {stake_name(@pool)} {@pool.token.symbol}
            </Regent.Primitives.button>
            <Regent.Primitives.button
              type="submit"
              name="kind"
              value="unstake"
              variant="secondary"
              class="token-swap__submit"
            >
              Unstake
            </Regent.Primitives.button>
          </div>
          <div :if={action(assigns) == :act} class="token-stake__actions token-stake__actions--open">
            <Regent.Primitives.button type="submit" name="kind" value="claim" variant="secondary">
              Claim rewards
            </Regent.Primitives.button>
            <Regent.Primitives.button
              :if={@pool.kind == :stocks}
              type="submit"
              name="kind"
              value="settle"
              variant="secondary"
            >
              Settle for stakers
            </Regent.Primitives.button>
            <Regent.Primitives.button type="submit" name="kind" value="collect" variant="secondary">
              Collect trading fees
            </Regent.Primitives.button>
          </div>
          <Regent.Primitives.button
            :if={action(assigns) == :sign_in}
            type="button"
            class="token-swap__submit"
            data-account-target="sign-in"
          >
            Sign in
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={action(assigns) == :closed}
            type="button"
            variant="secondary"
            class="token-swap__submit token-swap__submit--idle"
            disabled
          >
            Staking opens after launch
          </Regent.Primitives.button>

          <p :if={@error || (is_nil(@review) && @notice)} class="token-swap__error" role="alert">
            {@error || @notice}
          </p>
        </form>

        <.stake_review
          :if={@review}
          id={"#{@id}-review"}
          title={title(@review.kind)}
          facts={@review.review}
          steps={steps(@review, @sent)}
          next_step={next_step(@review, @sent)}
          stalled={stalled(@sent)}
          notice={@notice}
          target={@myself}
          wallet={@wallet}
          browser_wallets={@browser_wallets}
        />
      </div>
    </section>
    """
  end

  @impl true
  # The wallets this tab has connected, whenever they change: only for the note.
  def handle_event("browser_wallets", params, socket),
    do: {:noreply, assign(socket, browser_wallets: SignedInWallet.reported(params))}

  def handle_event("form-" <> revision, params, socket) do
    if revision == Integer.to_string(socket.assigns.revision),
      do: {:noreply, entered(socket, params)},
      else: {:noreply, socket}
  end

  def handle_event("fill", %{"percent" => percent}, socket)
      when percent in ["25", "50", "75", "100"] do
    case socket.assigns.position do
      %{balance: balance} ->
        amount = StakeActions.portion(balance, String.to_integer(percent))

        {:noreply,
         assign(socket,
           amount: amount,
           error: nil,
           notice: nil,
           revision: socket.assigns.revision + 1
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("review_all", %{"kind" => kind}, %{assigns: %{position: position}} = socket)
      when kind in ["stake", "unstake"] and is_map(position) do
    balance = if kind == "stake", do: position.balance, else: position.staked

    handle_event(
      "review",
      %{"kind" => kind, "amount" => StakeActions.portion(balance, 100)},
      socket
    )
  end

  def handle_event("review", %{"kind" => name} = params, socket) when is_map_key(@kinds, name) do
    socket = entered(socket, params)

    request = %{
      kind: Map.fetch!(@kinds, name),
      launch: socket.assigns.launch,
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
    do: {:noreply, assign(socket, notice: wallet_failure_copy(reason, socket.assigns.review))}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Reads run off the page's own process, and an answer for a wallet or a sent
  # step the page has since left is dropped.
  @impl true
  def handle_async(:position, {:ok, {wallet, {:ok, position}}}, socket) do
    if wallet == socket.assigns.wallet,
      do: {:noreply, assign(socket, position: position)},
      else: {:noreply, socket}
  end

  def handle_async({:recheck, name}, {:ok, {hash, attempts, read}}, socket) do
    case socket.assigns.sent[name] do
      %{hash: ^hash} -> {:noreply, read(socket, name, hash, attempts, read)}
      _left -> {:noreply, socket}
    end
  end

  def handle_async(_read, _unavailable, socket), do: {:noreply, socket}

  defp entered(socket, params) do
    amount = params |> Map.get("amount", socket.assigns.amount) |> limited()

    error =
      if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
        do: nil,
        else: "Enter an amount using digits and a decimal point."

    assign(socket, amount: amount, error: error, notice: nil)
  end

  defp limited(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp limited(_value), do: ""

  defp positioned(%{assigns: %{wallet: wallet, pool: pool}} = socket) when is_binary(wallet) do
    start_async(socket, :position, fn -> {wallet, StakeActions.position(pool, wallet)} end)
  end

  defp positioned(socket), do: assign(socket, position: nil)

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
      do: finished(socket, sent),
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

  # A read that failed is not an answer about the step; it is read again.
  defp read(socket, name, hash, attempts, {:error, error}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, name, sent(hash, :pending, attempts, nil)),
      notice: if(attempts == 0, do: copy(refusal(error)))
    )
    |> rechecked(name)
  end

  defp sent(hash, outcome, attempts, result),
    do: %{hash: hash, outcome: outcome, attempts: attempts, result: result}

  defp last_step?(%{steps: steps}, name), do: List.last(steps)["step"] == name

  # Every figure on the card moved, so the page reads the pool again and the
  # wallet's own figures follow from that read.
  defp finished(socket, sent) do
    results = for %{"step" => name} <- socket.assigns.review.steps, do: sent[name].result
    send(self(), :reload_pool)

    socket
    |> assign(
      amount: "",
      notice: nil,
      done: %{kind: socket.assigns.review.kind, results: results}
    )
    |> closed()
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

  # The signed-in wallet; every read that matters proves it against the session
  # again. A review belongs to the wallet it was made for.
  defp adopt(socket, wallet),
    do: socket |> assign(wallet: wallet, position: nil) |> reviewed_for_wallet()

  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet, do: socket, else: closed(socket)
  end

  defp reviewed_for_wallet(socket), do: socket

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp action(%{read_only?: true}), do: :closed
  defp action(%{authenticated: false}), do: :sign_in
  defp action(_assigns), do: :act

  defp lead(%{kind: :agent} = pool),
    do:
      "Stakers share this launch's revenue as it arrives: 1% of every trade, the locked liquidity's trading fees once anyone collects them, and anything else paid to the staking contract, in #{pool.fees.splitter.dollar.symbol}, #{pool.currency.symbol} and #{pool.token.symbol}. Each staked #{pool.token.symbol} earns its share of the whole supply's cut. Unstake any time after the block you staked in."

  defp lead(%{kind: :stocks} = pool),
    do:
      "Stakers share this launch's trading fees: 1% of every trade's #{pool.currency.symbol} side plus the locked liquidity's fees, paid in #{pool.fees.splitter.dollar.symbol}, #{pool.token.symbol} and #{pool.currency.symbol}. Unstake any time after the block you staked in."

  defp uncollected(nil, _pool), do: "Not readable right now"

  defp uncollected(%{token_amount: token, currency_amount: currency}, pool),
    do: "#{token} #{pool.token.symbol} · #{currency} #{pool.currency.symbol}"

  defp claimable(%{dollar: dollar, token: token, stock: stock}, pool),
    do:
      "#{dollar.shown} #{pool.fees.splitter.dollar.symbol} · #{token.shown} #{pool.token.symbol} · #{stock.shown} #{pool.currency.symbol}"

  defp steps(review, sent) do
    Enum.map(review.steps, fn %{"step" => name} ->
      %{name: name, label: step_label(name, review), state: step_state(sent[name])}
    end)
  end

  # One button at a time: the first step the wallet has not sent yet, or one
  # that reverted. A sent step moves the button on at once; nothing waits for
  # the network before the next press can reach the wallet.
  defp next_step(review, sent) do
    Enum.find(steps(review, sent), &(&1.state in [:ready, :reverted]))
  end

  defp stalled(sent) do
    for {name, %{outcome: :pending, attempts: attempts}} <- sent,
        attempts >= @recheck_limit,
        do: name
  end

  defp step_label("token_approval", review),
    do: "Approve #{review.envelope["arguments"]["token_symbol"]}"

  defp step_label("stake", _review), do: "Confirm stake"
  defp step_label("unstake", _review), do: "Confirm unstake"
  defp step_label("claim", _review), do: "Confirm claim"
  defp step_label("settle", _review), do: "Confirm settlement"
  defp step_label("collect_full_range", _review), do: "Collect the full-range fees"
  defp step_label("collect_stock_only", _review), do: "Collect the one-sided fees"

  defp step_state(nil), do: :ready
  defp step_state(%{outcome: :pending}), do: :sent
  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted

  defp reverted_copy(:stake),
    do: "The stake did not go through and nothing moved. Close this and review again."

  defp reverted_copy(kind) when kind in [:unstake, :claim],
    do:
      "That did not go through and nothing moved. Staking and leaving in the same block is not allowed: wait a moment and try again."

  defp reverted_copy(:settle),
    do: "Nothing was waiting for stakers, so there was nothing to settle."

  defp reverted_copy(:collect), do: @generic

  defp wallet_failure_copy("wallet_unavailable", _review),
    do:
      "Nothing was sent. Check the wallet you signed in with is connected and open, then press again."

  defp wallet_failure_copy("network_mismatch", %{envelope: %{"chain_id" => chain_id}}) do
    if test_chain?(chain_id),
      do:
        "Your wallet is connected to a different network under this test network's number. Point that network at the test network in your wallet's settings, then try again. Nothing was sent.",
      else:
        "Your wallet is on a different network. Switch it to #{network_name(chain_id)}, then try again. Nothing was sent."
  end

  defp wallet_failure_copy("wallet_declined", _review),
    do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed", _review),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown, _review), do: @generic

  defp test_chain?(chain_id),
    do: Autolaunch.Lab.test_chain?(chain_id) or Autolaunch.Robinhood.Lab.test_chain?(chain_id)

  defp network_name(chain_id) do
    if chain_id == Autolaunch.Robinhood.Lab.chain_id(),
      do: Autolaunch.Robinhood.Lab.network_name(chain_id),
      else: Autolaunch.Lab.network_name(chain_id)
  end

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :facts, :list, required: true, doc: "[label, value] pairs"
  attr :steps, :list, required: true
  attr :next_step, :map, default: nil
  attr :stalled, :list, default: []
  attr :notice, :string, default: nil
  attr :target, :any, default: nil
  attr :wallet, :string, default: nil
  attr :browser_wallets, :list, default: []

  @doc "The review panel over a staking card: the reviewed facts and the wallet steps, one button at a time."
  def stake_review(assigns) do
    ~H"""
    <section id={@id} class="token-swap__review" aria-labelledby={@id <> "-title"}>
      <header class="token-swap__review-head">
        <h3 id={@id <> "-title"}>{@title}</h3>
        <Regent.Primitives.button
          type="button"
          variant="quiet"
          phx-click="close_review"
          phx-target={@target}
          aria-label="Close"
          title="Close"
        >
          <.cross size="20" />
        </Regent.Primitives.button>
      </header>

      <dl class="token-swap__review-facts">
        <div :for={[label, value] <- @facts}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>

      <p class="token-swap__review-rule"><span>Continue in your wallet</span></p>

      <ol class="token-swap__steps" role="list">
        <li
          :for={{step, index} <- Enum.with_index(@steps, 1)}
          data-step={step.name}
          data-state={step.state}
          data-current={@next_step && @next_step.name == step.name}
        >
          <span class="token-swap__step-mark" aria-hidden="true"></span>
          <span>{step.label}</span>
          <span class="token-swap__step-note">
            {step_note(step, index, length(@steps), @next_step)}
          </span>
        </li>
      </ol>

      <SignedInWallet.note :if={@next_step} signed_in={@wallet} browser={@browser_wallets} />
      <Regent.Primitives.button
        :if={@next_step}
        type="button"
        class="token-swap__submit token-swap__wallet-step"
        data-reviewed-step={@next_step.name}
      >
        <span class="token-swap__wallet-step-label">{@next_step.label}</span>
        <span class="token-swap__wallet-step-wait">
          <span class="token-swap__spinner" aria-hidden="true"></span> Confirm in wallet
        </span>
      </Regent.Primitives.button>
      <Regent.Primitives.button
        :for={name <- @stalled}
        type="button"
        variant="secondary"
        class="token-swap__submit"
        phx-click="check_step"
        phx-value-step={name}
        phx-target={@target}
      >
        Check again
      </Regent.Primitives.button>

      <p :if={@notice} class="token-swap__error" role="alert">{@notice}</p>
    </section>
    """
  end

  defp step_note(%{state: :done}, _index, _count, _next), do: "Done"
  defp step_note(%{state: :sent}, _index, _count, _next), do: "Waiting for the network"
  defp step_note(%{state: :reverted}, _index, _count, _next), do: "Did not go through"

  defp step_note(%{name: name}, index, count, %{name: name}) when count > 1,
    do: "Step #{index} of #{count}"

  defp step_note(_step, _index, _count, _next), do: nil

  attr :id, :string, required: true
  attr :done, :map, required: true
  attr :share, :map, default: nil, doc: "the post and picture a stake can be shared with"
  attr :dismiss_event, :string, required: true
  attr :target, :any, default: nil

  defp stake_done(assigns) do
    ~H"""
    <aside id={@id} class="token-swap__toast" role="status">
      <div>
        <strong>{done_title(@done.kind)}</strong>
        <p :for={line <- done_lines(@done)}>{line}</p>
        <ShareDialog.share_dialog
          :if={@done.kind == :stake && @share}
          id={"#{@id}-share"}
          message={@share.message}
          image={@share.image}
        />
      </div>
      <Regent.Primitives.button
        type="button"
        variant="quiet"
        phx-click={@dismiss_event}
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <.cross size="18" />
      </Regent.Primitives.button>
    </aside>
    """
  end

  defp stake_name(%{kind: :agent}), do: "Revstake"
  defp stake_name(_pool), do: "Memestake"

  defp share(%{share_url: url, share_image: image, pool: pool, launch: launch})
       when is_binary(url) and is_binary(image) do
    chain = if launch.chain == :robinhood, do: "Robinhood", else: "Base"

    %{
      message: "I just staked $#{pool.token.symbol} on Autolaunch (#{chain}). #{url}",
      image: image
    }
  end

  defp share(_assigns), do: nil

  defp title(:stake), do: "You’re staking"
  defp title(:unstake), do: "You’re unstaking"
  defp title(:claim), do: "You’re claiming"
  defp title(:settle), do: "Settling for stakers"
  defp title(:collect), do: "Collecting trading fees"

  defp done_title(:stake), do: "Staked"
  defp done_title(:unstake), do: "Unstaked"
  defp done_title(:claim), do: "Claimed"
  defp done_title(:settle), do: "Settled for stakers"
  defp done_title(:collect), do: "Trading fees collected"

  defp done_lines(%{results: results}) do
    for %{} = result <- results, do: done_line(result)
  end

  defp done_line(%{"kind" => kind, "amount_units" => amount, "token_symbol" => symbol})
       when kind in ["stake", "unstake"],
       do: "#{amount} #{symbol}"

  defp done_line(%{"kind" => "claim"} = result) do
    "#{result["dollar_units"]} #{result["dollar_symbol"]} · #{result["token_units"]} #{result["token_symbol"]} · #{result["stock_units"]} #{result["currency_symbol"]}"
  end

  defp done_line(%{"kind" => "settle"} = result),
    do: "#{result["settled_units"]} #{result["currency_symbol"]} moved to the staking contract"

  defp done_line(%{"kind" => "collect"} = result) do
    "#{result["token_units"]} #{result["token_symbol"]} · #{result["currency_units"]} #{result["currency_symbol"]} moved to the staking contract"
  end

  attr :size, :string, required: true

  @doc "The close mark on a review panel or a toast."
  def cross(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" width={@size} height={@size} fill="none" aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
    </svg>
    """
  end
end
