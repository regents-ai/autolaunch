defmodule AutolaunchWeb.StakeComponent do
  @moduledoc """
  The staking actions of a graduated launch on its Base or Robinhood token
  page, in one of two places, named by `part`:

    * `:stake` - the Stake and Unstake views of the page's trade widget, the
      one showing named by `mode`. Stake sends the wallet's whole balance;
      Unstake sends an amount typed or picked as a share of the stake. It
      tells the page whether the wallet has a stake (`{:staked, boolean}`), so
      the widget offers Unstake only to a wallet that has one.
    * `:claim` - Claim Rewards under the widget: what the wallet can claim in
      each asset its staking pays, the claim itself, Settle contract (every
      trading fee waiting for stakers moved into the staking contract, open to
      anyone) and, for a launch that vests to its creator, the release of the
      creator's tokens. Above it, a button copies the token's full details
      (`details`, see `AutolaunchWeb.TokenDetails`) with this wallet's own
      figures for the person to paste to their agent.

  The `launch` assign names the launch: `%{chain: :base, auction: record}` or
  `%{chain: :robinhood, auction: record}`; `pool` is its current facts. A
  panel over the part walks the wallet through each reviewed action and closes
  itself when the chain confirms it.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); the part shows that wallet's
  figures, or the signed-in wallet's until Privy reports one, and a note names
  both while the wallet app has another one open.

  Nothing is stored. The figures are public reads; the review lives on this
  page only, the browser reports a hash and stops, and every outcome on
  screen is the server's own read of that hash against the review it was sent
  from.
  """
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Client
  alias Autolaunch.Stocks.{Amounts, StakeActions}
  alias AutolaunchWeb.Components.{ShareDialog, SwapForm}
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.{OnchainSteps, TokenDetails, TokenDisplay}
  alias RegentChain.{Presses, Review}

  @copy %{
    authentication_required: "Sign in to use your wallet here.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Your wallet changed during the review, so nothing was prepared. Review again.",
    invalid_address: "Open one of your account's wallets in your wallet app, then review again.",
    chain_unavailable: "The staking contract could not be read just now. Try again in a moment.",
    invalid_chain_response:
      "The staking contract gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    stake_unavailable: "Staking is not available for this token yet.",
    nothing_to_stake: "This wallet holds none of this token.",
    nothing_to_settle: "No trading fees are waiting to be settled.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this token supports.",
    amount_too_large: "That amount is too large to move at once.",
    amount_above_stake: "You have less than that staked."
  }
  @generic "That did not go through. Try again in a moment."
  @kinds %{
    stake: %{"stake" => :stake, "unstake" => :unstake},
    claim: %{"claim" => :claim, "settle" => :settle, "release" => :release}
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(&take_account/2)
     |> OnchainSteps.init()
     |> assign(scope: nil, wallet: nil, signer: nil, mismatch: nil, revision: 0, told: nil)}
  end

  @impl true
  def update(assigns, socket) do
    mode = socket.assigns[:mode]

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:mode, fn -> nil end)
      |> assign_new(:details, fn -> nil end)
      |> assign_new(:authenticated, fn -> false end)
      |> assign_new(:current_human_id, fn -> nil end)
      |> assign_new(:session_lease, fn -> nil end)
      |> assign_new(:share_url, fn -> nil end)
      |> assign_new(:share_image, fn -> nil end)
      |> assign(read_only?: Autolaunch.Prelaunch.read_only?())
      |> scoped()
      |> OnchainSteps.adopt()

    # Another view of the widget closes a review opened from the one before.
    socket =
      if mode && mode != socket.assigns.mode && socket.assigns.review,
        do: socket |> assign(notice: nil) |> closed(),
        else: socket

    {:ok, followed(socket)}
  end

  # Another launch or another sign-in starts the part again.
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
        amount: "",
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

  # The account as it reads now, before each event and background result
  # (`Session.check_component_lease/2`): a change to its wallets moves the
  # part onto them.
  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &followed/1)

  # The part follows the wallet that may act. A review is built for one
  # signer, so another one closes it; the figures are that signer's, or the
  # signed-in wallet's while no wallet on the account is active, and a pool
  # read at a new block reads them again.
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
        else: socket |> assign(wallet: wallet) |> positioned_as(nil)

    read_for = {socket.assigns.pool.block, wallet}

    if socket.assigns.read_for == read_for,
      do: socket,
      else: socket |> assign(read_for: read_for) |> positioned()
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: closed(socket)

  @impl true
  def render(%{part: :stake} = assigns) do
    ~H"""
    <div id={@id} class="token-trade__stake" phx-hook="OnchainSteps" data-stake-panel>
      <.stake_done
        :if={@done}
        id={"#{@id}-done"}
        done={@done}
        share={share(assigns)}
        dismiss_event="dismiss_done"
        target={@myself}
      />

      <div class="token-swap__stack">
        <div :if={@mode != :unstake} class="token-swap__form" inert={!is_nil(@review)}>
          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <span class="token-trade__label">You stake</span>
            </div>
            <div
              id={@id <> "-stake-figure"}
              class="token-swap__amount-row"
              phx-hook="MotionCount"
              data-variant={AutolaunchWeb.Motion.standard("count")}
            >
              <output
                class="token-trade__figure"
                title={balance(@position) && "#{balance(@position).shown} #{@pool.token.symbol}"}
                data-empty={!balance(@position)}
                data-count
              >
                {big(balance(@position))}
              </output>
              <span class="token-swap__currency" title={@pool.token.symbol}>
                <span>{@pool.token.symbol}</span>
              </span>
            </div>
            <p class="token-swap__leg-foot">{stake_foot(@position)}</p>
          </div>

          <Regent.Primitives.button
            :if={action(assigns) == :act}
            type="button"
            class="token-swap__submit"
            phx-click="review"
            phx-value-kind="stake"
            phx-target={@myself}
            disabled={nothing_to_stake?(@position)}
            data-press="motion"
            phx-mounted={JS.ignore_attributes("style")}
          >
            <span class="site-glint" aria-hidden="true"></span>Stake {@pool.token.symbol}
          </Regent.Primitives.button>
          <p :if={action(assigns) == :act && nothing_to_stake?(@position)} class="token-trade__reason">
            No {@pool.token.symbol} in this wallet
          </p>
          <.idle_button action={action(assigns)} />
          <.refusal_line id={"#{@id}-stake-refusal"} text={@error || (is_nil(@review) && @notice)} />
        </div>

        <form
          :if={@mode == :unstake}
          id={"#{@id}-form-#{@revision}"}
          class="token-swap__form"
          aria-label={"Unstake #{@pool.token.symbol}"}
          phx-change={"form-#{@revision}"}
          phx-submit="review"
          phx-target={@myself}
          inert={!is_nil(@review)}
        >
          <input type="hidden" name="kind" value="unstake" />
          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <label for={@id <> "-amount"}>You unstake</label>
              <div
                :if={is_map(@position)}
                class="token-swap__portions"
                role="group"
                aria-label="Part of your stake"
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
                aria-label={"Amount of #{@pool.token.symbol} to unstake"}
                aria-invalid={to_string(!is_nil(@error))}
                phx-debounce="300"
              />
              <span class="token-swap__currency" title={@pool.token.symbol}>
                <span>{@pool.token.symbol}</span>
              </span>
            </div>
            <p class="token-swap__leg-foot">
              <span :if={is_map(@position)}>
                <TokenDisplay.tokens amount={@position.staked.shown} unit={@pool.token.symbol} />
                staked
              </span>
            </p>
          </div>

          <Regent.Primitives.button
            :if={action(assigns) == :act}
            type="submit"
            class="token-swap__submit"
            data-press="motion"
            phx-mounted={JS.ignore_attributes("style")}
          >
            <span class="site-glint" aria-hidden="true"></span>Unstake {@pool.token.symbol}
          </Regent.Primitives.button>
          <.idle_button action={action(assigns)} />
          <.refusal_line id={"#{@id}-unstake-refusal"} text={@error || (is_nil(@review) && @notice)} />
        </form>

        <.stake_review {review_assigns(assigns)} />
      </div>
    </div>
    """
  end

  def render(%{part: :claim} = assigns) do
    assigns = assign(assigns, rows: claim_rows(assigns.pool, assigns.position))

    ~H"""
    <div id={@id} class="token-claim" phx-hook="OnchainSteps">
      <.stake_done
        :if={@done}
        id={"#{@id}-done"}
        done={@done}
        dismiss_event="dismiss_done"
        target={@myself}
      />

      <Regent.Primitives.copy_button
        :if={@details}
        id={@id <> "-copy"}
        text={TokenDetails.text(@details, @wallet, @position)}
        variant="secondary"
        class="token-claim__copy"
      >
        Copy Full Token Details to Agent
      </Regent.Primitives.copy_button>

      <section class="token-claim__card" aria-labelledby={@id <> "-title"}>
        <div class="token-swap__stack">
          <div class="token-claim__body" inert={!is_nil(@review)}>
            <h2 id={@id <> "-title"} class="token-claim__title">Claim Rewards</h2>
            <ul
              id={@id <> "-rows"}
              class="token-claim__rows"
              phx-hook="MotionCount"
              data-variant={AutolaunchWeb.Motion.standard("count")}
            >
              <li :for={row <- @rows}>
                <span class="token-claim__what">{row.label}</span>
                <span :if={row.amount} class="token-claim__amount">
                  <TokenDisplay.tokens amount={row.amount} unit={row.symbol} />
                </span>
                <span :if={!row.amount} class="token-claim__amount token-claim__amount--missing">
                  {row.symbol}
                </span>
              </li>
            </ul>
            <p :if={!is_map(@position)} class="token-claim__note">{missing(@position)}</p>

            <Regent.Primitives.button
              :if={action(assigns) == :act}
              type="button"
              class="token-swap__submit"
              phx-click="review"
              phx-value-kind="claim"
              phx-target={@myself}
              data-press="motion"
              phx-mounted={JS.ignore_attributes("style")}
            >
              <span class="site-glint" aria-hidden="true"></span>Claim rewards
            </Regent.Primitives.button>
            <.idle_button action={action(assigns)} />

            <div :if={action(assigns) == :act} class="token-claim__more">
              <span class="token-claim__settle">
                <Regent.Primitives.button
                  type="button"
                  variant="secondary"
                  phx-click="review"
                  phx-value-kind="settle"
                  phx-target={@myself}
                  data-press="motion"
                  phx-mounted={JS.ignore_attributes("style")}
                >
                  <span class="site-glint" aria-hidden="true"></span>Settle contract
                </Regent.Primitives.button>
                <.info_tip
                  id={@id <> "-settle-tip"}
                  text="Moves the trading fees waiting in the pool into the staking contract, where they become rewards for everyone staked. Anyone can do this."
                >
                  <span class="visually-hidden">Settle contract</span>
                </.info_tip>
              </span>
              <Regent.Primitives.button
                :if={@pool.kind == :stocks && @pool.vesting}
                type="button"
                variant="secondary"
                phx-click="review"
                phx-value-kind="release"
                phx-target={@myself}
              >
                Release creator tokens
              </Regent.Primitives.button>
            </div>
            <.refusal_line id={"#{@id}-refusal"} text={is_nil(@review) && @notice} />
          </div>

          <.stake_review {review_assigns(assigns)} />
        </div>
      </section>
    </div>
    """
  end

  attr :action, :atom, required: true

  defp idle_button(%{action: :sign_in} = assigns) do
    ~H"""
    <Regent.Primitives.button type="button" class="token-swap__submit" data-account-target="sign-in">
      Sign in
    </Regent.Primitives.button>
    """
  end

  defp idle_button(%{action: :closed} = assigns) do
    ~H"""
    <Regent.Primitives.button
      type="button"
      variant="secondary"
      class="token-swap__submit token-swap__submit--idle"
      disabled
    >
      Staking opens after launch
    </Regent.Primitives.button>
    """
  end

  defp idle_button(assigns), do: ~H""

  attr :id, :string, required: true
  attr :text, :any, required: true

  defp refusal_line(assigns) do
    ~H"""
    <p
      :if={@text}
      id={@id}
      class="token-swap__error"
      role="alert"
      phx-hook="MotionRefusal"
      data-refused
    >
      {@text}
    </p>
    """
  end

  defp review_assigns(assigns) do
    %{
      id: "#{assigns.id}-review",
      open: !!assigns.review,
      title: assigns.review && title(assigns.prepared.kind),
      facts: (assigns.review && assigns.prepared.facts) || [],
      steps: steps(assigns),
      next_step: next_step(assigns),
      reverted: reverted(assigns),
      notice: assigns.press_note,
      target: assigns.myself,
      signer: assigns.review && assigns.review.signer,
      chain_name: assigns.review && assigns.review.chain.name,
      mismatch: assigns.mismatch
    }
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
      %{staked: staked} ->
        amount = StakeActions.portion(staked, String.to_integer(percent))

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

  def handle_event("review", %{"kind" => name} = params, socket) do
    case Map.fetch(@kinds[socket.assigns.part], name) do
      {:ok, kind} -> {:noreply, reviewed(socket, kind, params)}
      :error -> {:noreply, socket}
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
      {{:ok, position}, _shown} -> {:noreply, positioned_as(socket, position)}
      {{:error, _reason}, %{} = _last_read} -> {:noreply, socket}
      {{:error, _reason}, _none} -> {:noreply, positioned_as(socket, :unread)}
    end
  end

  def handle_async(:position, {:ok, _other_wallet}, socket), do: {:noreply, socket}

  def handle_async(:position, {:exit, _reason}, socket) do
    if is_map(socket.assigns.position),
      do: {:noreply, socket},
      else: {:noreply, positioned_as(socket, :unread)}
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

  defp reviewed(%{assigns: %{signer: nil}} = socket, _kind, params) do
    socket = entered(socket, params)
    assign(socket, notice: no_signer(socket.assigns))
  end

  defp reviewed(socket, kind, params) do
    socket = entered(socket, params)
    request = %{kind: kind, launch: socket.assigns.launch, amount: socket.assigns.amount}

    case StakeActions.prepare(request, socket.assigns.signer, opts(socket)) do
      {:ok, prepared} ->
        review =
          Review.new(socket.assigns.id, socket.assigns.signer, prepared.chain, prepared.steps)

        socket
        |> assign(prepared: prepared, results: %{}, notice: nil, press_note: nil, done: nil)
        |> OnchainSteps.put_review(review)

      {:error, error} ->
        assign(socket, notice: copy(refusal(error)))
    end
  end

  defp no_signer(%{linked: nil}), do: copy(:authentication_required)
  defp no_signer(assigns), do: failure_note(assigns, "wallet_unavailable")

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

  defp positioned(socket), do: positioned_as(socket, nil)

  # The wallet's position as last read. The widget's part tells the page
  # whether the wallet has a stake, once per change.
  defp positioned_as(socket, position) do
    socket = assign(socket, position: position)
    staked? = match?(%{staked: %{atomic: atomic}} when atomic > 0, position)

    if socket.assigns.part == :stake and socket.assigns.told != staked? do
      send(self(), {:staked, staked?})
      assign(socket, told: staked?)
    else
      socket
    end
  end

  # A step landed: every figure it touched is read again, and what it moved is
  # read from its receipt. An approval moves nothing to show.
  defp confirmed(socket, %{hash: hash, name: name, review: review}) do
    socket = socket |> assign(read_for: nil) |> followed()

    if name == "token_approval",
      do: resulted(socket, hash, []),
      else: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)
  end

  # When every step of the open review has landed, the review closes and the
  # part says what moved; a receipt that could not be read leaves its line out.
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

  # Every figure moved, so the page reads the pool again and the wallet's own
  # figures follow from that read.
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

  defp balance(%{balance: balance}), do: balance
  defp balance(_unread), do: nil

  # The whole balance as the big figure: four significant digits, grouped.
  defp big(nil), do: "0"

  defp big(%{shown: shown}),
    do: shown |> TokenDisplay.short(:down) |> Amounts.grouped() |> TokenDisplay.zeros()

  defp stake_foot(:unread), do: "Your balance can't be read right now"
  defp stake_foot(_position), do: "All of it, in one step"

  # The server's own read says the wallet holds none, so a stake is certain
  # to be refused.
  defp nothing_to_stake?(%{balance: %{atomic: 0}}), do: true
  defp nothing_to_stake?(_position), do: false

  defp missing(:unread), do: "Your rewards can't be read right now."
  defp missing(_signed_out), do: "Sign in to see your rewards."

  # One row for each asset this launch's staking pays, and for any other
  # asset the wallet happens to have to claim.
  defp claim_rows(pool, position) do
    for {key, label, symbol} <- [
          {:token, "Token rewards", pool.token.symbol},
          {:stock, "Trading fees", pool.currency.symbol},
          {:dollar, "Revenue", pool.fees.splitter.dollar.symbol}
        ],
        key in TokenDetails.paid_assets(pool) or claimable?(position, key) do
      %{label: label, symbol: symbol, amount: claimable(position, key)}
    end
  end

  defp claimable(%{claimable: claimable}, key), do: Map.fetch!(claimable, key).shown
  defp claimable(_unread, _key), do: nil

  defp claimable?(%{claimable: claimable}, key), do: Map.fetch!(claimable, key).atomic > 0
  defp claimable?(_unread, _key), do: false

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

  defp step_label("stake", _prepared), do: "Confirm stake"
  defp step_label("unstake", _prepared), do: "Confirm unstake"
  defp step_label("claim", _prepared), do: "Confirm claim"
  defp step_label("settle", _prepared), do: "Settle the pool's fees"
  defp step_label("collect_full_range", _prepared), do: "Collect the full-range fees"
  defp step_label("collect_stock_only", _prepared), do: "Collect the one-sided fees"
  defp step_label("collect_new_only", _prepared), do: "Collect the one-sided fees"
  defp step_label("release", _prepared), do: "Confirm release"

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
    do: "That did not go through. Close this and review again for what is waiting now."

  defp reverted_copy(:release), do: @generic

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
  The review panel over a staking part: the reviewed facts and the wallet
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

      <p
        :if={@notice}
        id={"#{@id}-notice"}
        class="token-swap__error"
        role="alert"
        phx-hook="MotionRefusal"
        data-refused
      >
        {@notice}
      </p>
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
  defp title(:settle), do: "Settling the contract"
  defp title(:release), do: "Releasing the creator's tokens"

  defp done_title(:stake), do: "Staked"
  defp done_title(:unstake), do: "Unstaked"
  defp done_title(:claim), do: "Claimed"
  defp done_title(:settle), do: "Contract settled"
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
