defmodule AutolaunchWeb.StakeComponent do
  @moduledoc """
  The staking card of a graduated launch, on its Base or Robinhood token page:
  what the launch's staking contract holds, what this wallet has in it, an
  amount to stake or unstake, and the open actions (claim, collect the locked
  liquidity's trading fees, and for a memestock launch settle for stakers and,
  when it vests to its creator, release the creator's tokens; a Revstake
  launch's swap fee reaches its splitter on the trade itself). A
  panel over the card walks the wallet through each reviewed action and
  closes itself when the chain confirms it.

  The `launch` assign names the launch: `%{chain: :base, auction: record}` or
  `%{chain: :robinhood, auction: record}`; `pool` is its current facts.
  The card shows the wallet's rewards one asset to a row, its stake apart
  from them, and what staking the typed amount would change
  (`AutolaunchWeb.Components.TokenNext`); `supply` is the token's whole
  supply, which a Revstake share is of.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); the card shows that wallet's
  figures, or the signed-in wallet's until Privy reports one, and a note names
  both while the wallet app has another one open.

  Nothing is stored. The figures are public reads; the review lives on this
  page only, the browser reports a hash and stops, and every outcome on
  screen is the server's own read of that hash against the review it was sent
  from.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Client
  alias Autolaunch.Stocks.{FeeSchedule, StakeActions}
  alias AutolaunchWeb.{AgentPress, OnchainSteps, TokenDisplay}
  alias AutolaunchWeb.Components.{ShareDialog, SwapForm, TokenNext}
  alias RegentChain.{Presses, Review}

  @copy %{
    authentication_required: "Sign in to stake from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then review again.",
    invalid_address: "Connect your wallet, then review again.",
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
    amount_above_stake: "You have less than that staked."
  }
  @generic "That did not go through. Try again in a moment."
  @kinds %{
    "stake" => :stake,
    "unstake" => :unstake,
    "claim" => :claim,
    "settle" => :settle,
    "collect" => :collect,
    "release" => :release
  }
  # The page tools an agent presses this card with, and the kind each reviews.
  @agent_kinds %{
    "autolaunch_stake" => "stake",
    "autolaunch_unstake" => "unstake",
    "autolaunch_claim_rewards" => "claim"
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init(&followed/1)
     |> assign(scope: nil, wallet: nil, signer: nil, mismatch: nil, revision: 0)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:authenticated, fn -> false end)
      |> assign_new(:current_human_id, fn -> nil end)
      |> assign_new(:session_lease, fn -> nil end)
      |> assign_new(:share_url, fn -> nil end)
      |> assign_new(:share_image, fn -> nil end)
      |> assign_new(:supply, fn -> nil end)
      |> assign(read_only?: Autolaunch.Prelaunch.read_only?())
      |> scoped()
      |> OnchainSteps.adopt()

    {:ok, followed(socket)}
  end

  # Another launch or another sign-in starts the card again.
  defp scoped(%{assigns: assigns} = socket) do
    scope =
      {assigns.launch.chain, launch_key(assigns.launch), assigns.current_human_id,
       assigns.session_lease}

    if assigns.scope == scope do
      socket
    else
      socket
      |> assign(
        scope: scope,
        amount: limited(Map.get(assigns, :initial_amount, "")),
        error: nil,
        position: nil,
        read_for: nil,
        notice: nil,
        done: nil
      )
      |> closed()
    end
  end

  defp launch_key(%{auction: %{id: id}}), do: id

  # The card follows the wallet that may act. A review is built for one
  # signer, so another one closes it; the figures on the card are that
  # signer's, or the signed-in wallet's while no wallet on the account is
  # active, and a pool read at a new block reads them again.
  defp followed(socket) do
    %{linked: linked, active: active, signed_in: signed_in} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    wallet = signer || signed_in

    socket =
      socket
      |> assign(signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))
      |> reviewed_for_signer(signer)

    socket =
      if wallet == socket.assigns.wallet,
        do: socket,
        else: assign(socket, wallet: wallet, position: nil)

    read_for = {socket.assigns.pool.block, wallet}

    if socket.assigns.read_for == read_for,
      do: socket,
      else: socket |> assign(read_for: read_for) |> positioned()
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: closed(socket)

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap token-stake"
      data-stake-panel
      data-agent-tools={agent_tools()}
      phx-hook="OnchainSteps"
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
        {stake_name(@pool)} <span class="ticker">{@pool.token.symbol}</span>
      </h2>
      <p class="token-stake__lead">
        Tokens are not locked. You can unstake at any time after the block in which you staked.
      </p>
      <p :if={@wallet} class="token-stake__lead">
        Figures for
        <span class="token-stake__wallet" title={@wallet}>{RegentFormat.short_address(@wallet)}</span>
      </p>
      <details>
        <summary>How rewards work</summary>
        <p>
          <TokenDisplay.marked
            text={lead(@pool)}
            tickers={[@pool.token.symbol, @pool.currency.symbol, @pool.fees.splitter.dollar.symbol]}
          />
        </p>
      </details>

      <TokenNext.stake_figures
        id={"#{@id}-figures"}
        pool={@pool}
        position={@position}
      />

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
                :if={is_map(@position)}
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
              <span :if={is_map(@position)}>
                <TokenDisplay.tokens amount={@position.balance.shown} unit={@pool.token.symbol} />
                in your wallet
              </span>
            </p>
          </div>

          <div :if={action(assigns) == :act && is_map(@position)} class="token-stake__actions">
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
            <Regent.Primitives.button
              :if={@pool.kind == :stocks && @pool.vesting}
              type="submit"
              name="kind"
              value="release"
              variant="secondary"
            >
              Release the creator's tokens
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
          id={"#{@id}-review"}
          open={!!@review}
          title={@review && title(@prepared.kind)}
          facts={(@review && @prepared.facts) || []}
          steps={steps(assigns)}
          next_step={next_step(assigns)}
          reverted={reverted(assigns)}
          notice={@press_note}
          target={@myself}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
        />
      </div>

      <TokenNext.stake_impact
        id={"#{@id}-impact"}
        pool={@pool}
        amount={@amount}
        position={@position}
        supply={@supply}
      />
    </section>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)

    socket =
      if active == socket.assigns.active,
        do: socket,
        else: assign(socket, active: active, press_note: nil)

    {:noreply, followed(socket)}
  end

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

      _unread ->
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
    case reviewed(socket, name, params) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  # An agent's press: the next step of the review open for the same action,
  # or the first step of a new one, sent at once as the button would send it.
  def handle_event("agent_press", %{"tool" => tool} = params, socket)
      when is_map_key(@agent_kinds, tool) do
    name = Map.fetch!(@agent_kinds, tool)
    input = agent_input(params["input"])

    case {action(socket.assigns), open_step(socket.assigns, name, input)} do
      {:sign_in, _step} ->
        {:reply, AgentPress.refused(copy(:authentication_required)), socket}

      {:closed, _step} ->
        {:reply, AgentPress.refused("Staking is not open on this site yet."), socket}

      {:act, %{name: step}} ->
        {:reply, sending(socket, step), socket}

      {:act, nil} ->
        case reviewed(socket, name, input) do
          {:ok, socket} ->
            [%{step: first} | _rest] = socket.assigns.review.steps
            {:reply, sending(socket, first), socket}

          {:error, socket} ->
            {:reply, AgentPress.refused(socket.assigns.notice), socket}
        end
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, socket |> OnchainSteps.sent(params) |> assign(notice: nil)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:stake, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Reads run off the page's own process, and an answer for a wallet or a
  # review the page has since left is dropped. A figure that could not be read
  # says so, and a later read that fails keeps the last one read for the same
  # wallet.
  @impl true
  def handle_async(:position, {:ok, {wallet, read}}, %{assigns: %{wallet: wallet}} = socket) do
    case {read, socket.assigns.position} do
      {{:ok, position}, _shown} -> {:noreply, assign(socket, position: position)}
      {{:error, _reason}, %{} = _last_read} -> {:noreply, socket}
      {{:error, _reason}, _none} -> {:noreply, assign(socket, position: :unread)}
    end
  end

  def handle_async(:position, {:ok, _other_wallet}, socket), do: {:noreply, socket}

  def handle_async(:position, {:exit, _reason}, socket) do
    if is_map(socket.assigns.position),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, position: :unread)}
  end

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  def handle_async({:result, hash}, result, socket) do
    logs =
      case result do
        {:ok, {:ok, %{"logs" => logs}}} when is_list(logs) -> logs
        _unread -> nil
      end

    {:noreply, resulted(socket, hash, logs)}
  end

  defp reviewed(%{assigns: %{signer: nil}} = socket, _name, params) do
    socket = entered(socket, params)
    socket = assign(socket, notice: no_signer(socket.assigns))

    if socket.assigns.linked && is_nil(socket.assigns.active),
      do: {:error, OnchainSteps.connect(socket)},
      else: {:error, socket}
  end

  defp reviewed(socket, name, params) do
    socket = entered(socket, params)

    request = %{
      kind: Map.fetch!(@kinds, name),
      launch: socket.assigns.launch,
      amount: socket.assigns.amount
    }

    case StakeActions.prepare(request, socket.assigns.signer, opts(socket)) do
      {:ok, prepared} ->
        review =
          Review.new(socket.assigns.id, socket.assigns.signer, prepared.chain, prepared.steps)

        socket =
          socket
          |> assign(prepared: prepared, results: %{}, notice: nil, press_note: nil, done: nil)
          |> OnchainSteps.put_review(review)

        {:ok, socket}

      {:error, error} ->
        {:error, assign(socket, notice: copy(refusal(error)))}
    end
  end

  defp no_signer(%{linked: nil}), do: copy(:authentication_required)
  defp no_signer(%{active: nil}), do: "Connect your wallet, then review again."

  defp no_signer(_assigns),
    do: "Switch to a wallet on your account in your wallet app, then review again."

  # The step the open review's button would send, when that review is for the
  # same action and amount; a claim takes no amount.
  defp open_step(%{prepared: %{kind: kind}, review: %{}} = assigns, name, input) do
    same_amount? = name == "claim" or Map.get(input, "amount") == assigns.amount

    if kind == Map.fetch!(@kinds, name) and same_amount?,
      do: SwapForm.pressable(next_step(assigns), steps(assigns))
  end

  defp open_step(_assigns, _name, _input), do: nil

  defp agent_input(%{} = input), do: Map.take(input, ["amount"])
  defp agent_input(_input), do: %{}

  defp sending(%{assigns: %{review: review, prepared: prepared}}, step),
    do: AgentPress.sending(review, step, &step_label(&1, prepared))

  defp agent_tools, do: @agent_kinds |> Map.keys() |> Enum.join(" ")

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

  defp positioned(%{assigns: %{wallet: wallet, pool: pool}} = socket) when is_binary(wallet),
    do: start_async(socket, :position, fn -> {wallet, StakeActions.position(pool, wallet)} end)

  defp positioned(socket), do: assign(socket, position: nil)

  # A step landed: every figure it touched is read again, and what it moved is
  # read from its receipt. An approval moves nothing to show.
  defp confirmed(socket, %{hash: hash, name: name, review: review}) do
    socket = socket |> assign(read_for: nil) |> followed()

    if name == "token_approval",
      do: resulted(socket, hash, []),
      else: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)
  end

  # When every step of the open review has landed, the review closes and the
  # card says what moved; a receipt that could not be read leaves its line out.
  defp resulted(%{assigns: %{review: %{} = review, prepared: prepared}} = socket, hash, logs) do
    case Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)) do
      %{review: %{id: id}, name: name} when id == review.id ->
        result = if logs, do: StakeActions.result(prepared.context, name, logs)
        results = Map.put(socket.assigns.results, name, result)
        socket = assign(socket, results: results)

        if Enum.all?(review.steps, &Map.has_key?(results, &1.step)),
          do: finished(socket),
          else: socket

      _other_review ->
        socket
    end
  end

  defp resulted(socket, _hash, _logs), do: socket

  # Every figure on the card moved, so the page reads the pool again and the
  # wallet's own figures follow from that read.
  defp finished(%{assigns: %{review: review, prepared: prepared, results: results}} = socket) do
    send(self(), :reload_pool)

    socket
    |> assign(
      amount: "",
      notice: nil,
      done: %{kind: prepared.kind, results: Enum.map(review.steps, &results[&1.step])}
    )
    |> closed()
  end

  defp closed(socket) do
    socket
    |> assign(prepared: nil, results: %{}, press_note: nil, revision: socket.assigns.revision + 1)
    |> OnchainSteps.put_review(nil)
  end

  defp failure_note(%{review: review} = assigns, reason) do
    chain_name = if review, do: review.chain.name, else: "this network"
    OnchainSteps.failure_note(reason, assigns.linked, assigns.active, chain_name)
  end

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
      "Stakers share this launch's revenue as it arrives: 2% of every trade, the locked liquidity's trading fees once anyone collects them, and anything else paid to the staking contract, in #{pool.fees.splitter.dollar.symbol}, #{pool.currency.symbol} and #{pool.token.symbol}. Each staked #{pool.token.symbol} earns its share of the whole supply's cut. Unstake any time after the block you staked in."

  defp lead(%{kind: :stocks} = pool),
    do:
      "Stakers share this launch's trading fees: #{FeeSchedule.lane(pool.chain, pool.version, :stakers).rate} of every trade's #{pool.currency.symbol} side plus the locked liquidity's fees, paid in #{pool.fees.splitter.dollar.symbol}, #{pool.token.symbol} and #{pool.currency.symbol}. Unstake any time after the block you staked in."

  defp steps(%{review: nil}), do: []

  defp steps(%{review: review, prepared: prepared, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: step_label(name, prepared), state: step_state(entry), entry: entry}
    end)
  end

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. A sent step moves the button on
  # at once; nothing waits for the network before the next press can reach the
  # wallet.
  defp next_step(%{review: %{}} = assigns),
    do: Enum.find(steps(assigns), &(&1.state in [:ready, :reverted, :other]))

  defp next_step(_assigns), do: nil

  defp step_label("token_approval", prepared),
    do: "Approve #{prepared.context.token_symbol}"

  defp step_label("stake", _review), do: "Confirm stake"
  defp step_label("unstake", _review), do: "Confirm unstake"
  defp step_label("claim", _review), do: "Confirm claim"
  defp step_label("settle", _review), do: "Confirm settlement"
  defp step_label("collect_full_range", _review), do: "Collect the full-range fees"
  defp step_label("collect_stock_only", _review), do: "Collect the one-sided fees"
  defp step_label("collect_new_only", _review), do: "Collect the one-sided fees"
  defp step_label("release", _review), do: "Confirm release"

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp reverted(%{review: %{}, prepared: %{kind: kind}} = assigns) do
    if Enum.any?(steps(assigns), &(&1.state == :reverted)), do: reverted_copy(kind)
  end

  defp reverted(_assigns), do: nil

  defp reverted_copy(:stake),
    do:
      "The stake did not go through and nothing moved. Press again, or close this and review again."

  defp reverted_copy(kind) when kind in [:unstake, :claim],
    do:
      "That did not go through and nothing moved. Staking and leaving in the same block is not allowed: wait a moment and try again."

  defp reverted_copy(:settle),
    do: "Nothing was waiting for stakers, so there was nothing to settle."

  defp reverted_copy(kind) when kind in [:collect, :release], do: @generic

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  attr :id, :string, required: true
  attr :open, :boolean, required: true, doc: "whether a review is on the page"
  attr :title, :string, default: nil
  attr :facts, :list, default: [], doc: "[label, value] pairs"
  attr :steps, :list, required: true
  attr :next_step, :map, default: nil
  attr :reverted, :string, default: nil
  attr :notice, :string, default: nil
  attr :target, :any, default: nil
  attr :signer, :string, default: nil
  attr :chain_name, :string, default: nil
  attr :mismatch, :string, default: nil

  @doc """
  The review panel over a staking card: the reviewed facts and the wallet
  steps, one button at a time. It stays in the page and is only hidden while
  nothing is reviewed, so its wallet button is never replaced.
  """
  def stake_review(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap__review"
      aria-labelledby={@id <> "-title"}
      hidden={!@open}
    >
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
            {SwapForm.step_note(step, index, length(@steps), @next_step)}
          </span>
        </li>
      </ol>

      <SwapForm.wallet_step
        next_step={@next_step}
        steps={@steps}
        reverted={@reverted}
        signer={@signer}
        chain_name={@chain_name}
        mismatch={@mismatch}
        check_event="check_again"
        target={@target}
      />

      <p :if={@notice} class="token-swap__error" role="alert">{@notice}</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :done, :map, required: true
  attr :share, :map, default: nil, doc: "the post and picture a stake can be shared with"
  attr :dismiss_event, :string, required: true
  attr :target, :any, default: nil

  defp stake_done(assigns) do
    ~H"""
    <aside
      id={@id}
      class="token-swap__toast"
      role="status"
      phx-hook="Toast"
      data-variant={AutolaunchWeb.Motion.standard("toast")}
    >
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
  defp title(:release), do: "Releasing the creator's tokens"

  defp done_title(:stake), do: "Staked"
  defp done_title(:unstake), do: "Unstaked"
  defp done_title(:claim), do: "Claimed"
  defp done_title(:settle), do: "Settled for stakers"
  defp done_title(:collect), do: "Trading fees collected"
  defp done_title(:release), do: "Released to the creator"

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

  defp done_line(%{"kind" => "release"} = result),
    do: "#{result["token_units"]} #{result["token_symbol"]} sent to the creator"

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
