defmodule AutolaunchWeb.EarnComponent do
  @moduledoc """
  The wallet panel for one Earn product: the wallet's balance in the market
  and its USDC, an amount with Max, and the Deposit or Withdraw button, which
  opens a review over the panel with the steps the wallet sends, one button at
  a time, the way covered calls' panels work. The review closes when the chain
  confirms the last step, and the page then says what moved (`toast/1`, from
  `{:earn_done, done}`).

  The page passes `product`, `decimals` (the asset's, from the market's first
  reading), `kind` (`:deposit` or `:withdraw`, the page's tabs), the panel's
  `session_lease` and `current_human_id`. A landed step tells the page with
  `{:earn_changed, product_id}`, so it reads the market again.

  The server builds every step (`Autolaunch.Earn.prepare_earn_steps/4`, the
  same action agents call) for the wallet that may act
  (`AutolaunchWeb.OnchainSteps`), and every press of the wallet button goes
  straight to the wallet. A deposit's approval is its own step; one the chain
  already holds shows as done. The button is disabled only when the chain, read
  at the latest block for the amount as it stands, makes the step certain to
  fail, with the reason beside it. An amount that does not read is said under
  the field and never disables anything.

  Max fills in the wallet's USDC for a deposit. For a withdrawal it asks for
  everything, which withdraws the balance as it stands when the step lands; a
  typed figure, even one equal to the balance, is that figure only.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Earn
  alias Autolaunch.Earn.{Amount, Answer}
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.{OnchainSteps, StakeComponent}
  alias Phoenix.LiveView.JS
  alias Regent.Primitives, as: P
  alias RegentChain.{Presses, Review}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(&take_account/2)
     |> OnchainSteps.init()
     |> assign(
       text: "",
       max: false,
       quote: nil,
       refusal: nil,
       reviewed: nil,
       landed: MapSet.new(),
       openings: 0,
       notice: nil,
       mismatch: nil,
       held: nil,
       held_for: nil,
       held_reads: 0
     )}
  end

  @impl true
  def update(assigns, socket) do
    # A new tab starts empty, and a review open on the other one closes.
    changed? = socket.assigns[:kind] not in [nil, assigns.kind]
    socket = assign(socket, assigns)

    socket =
      if changed?,
        do: socket |> assign(text: "", max: false, notice: nil) |> closed(),
        else: socket

    {:ok, socket |> OnchainSteps.adopt() |> sync()}
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)

    if active == socket.assigns.active,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(active: active, press_note: nil) |> sync()}
  end

  # The page came back into view, the wallet changed or a press went out: the
  # chain is read again, so a button the chain held back comes back once it
  # allows the step.
  def handle_event("refresh_funds", _params, socket),
    do: {:noreply, socket |> update(:held_reads, &(&1 + 1)) |> sync()}

  def handle_event("change", %{"amount" => text}, socket),
    do: {:noreply, socket |> typed(text) |> assign(notice: nil) |> sync()}

  def handle_event("max", _params, socket) do
    case {socket.assigns.kind, socket.assigns.held} do
      {:deposit, %{usdc: usdc}} ->
        {:noreply,
         socket |> assign(text: Amount.text(usdc, socket.assigns.decimals), max: false) |> sync()}

      {:withdraw, %{balance: balance}} ->
        {:noreply,
         socket
         |> assign(text: Amount.text(balance, socket.assigns.decimals), max: true)
         |> sync()}

      {_kind, nil} ->
        {:noreply, socket}
    end
  end

  # The form sends its amount with the press, so a figure typed a moment ago
  # is the one reviewed.
  def handle_event("review", params, socket) do
    socket = if is_map_key(params, "amount"), do: typed(socket, params["amount"]), else: socket
    {:noreply, reviewed(socket)}
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, socket |> OnchainSteps.sent(params) |> assign(notice: nil)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:earn, reason)
        %{linked: linked, active: active} = socket.assigns

        {:noreply,
         assign(socket, press_note: OnchainSteps.failure_note(reason, linked, active, "Base"))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  @impl true
  def handle_async(:quote, {:ok, {request, signer, result}}, socket) do
    if {:ok, request} == request(socket.assigns) and signer == signer(socket) do
      case result do
        {:ok, prepared} ->
          {:noreply, assign(socket, quote: {request, signer, prepared}, refusal: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, quote: nil, refusal: reason)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:quote, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, quote: nil, refusal: :chain_unavailable)}

  def handle_async(:held, {:ok, {key, held}}, socket) do
    if key == socket.assigns.held_for,
      do: {:noreply, assign(socket, held: held)},
      else: {:noreply, socket}
  end

  def handle_async(:held, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2, &step_reverted/2)}

  # A figure other than the one Max filled in is that figure only.
  defp typed(socket, text) when is_binary(text) do
    if text == socket.assigns.text,
      do: socket,
      else: assign(socket, text: text, max: false)
  end

  defp typed(socket, _text), do: socket

  # The figures follow the wallet that may act and the amount as it stands. A
  # review open for another wallet closes: its steps were built for that wallet
  # only.
  defp sync(socket) do
    signer = signer(socket)

    socket =
      case socket.assigns.review do
        %{signer: ^signer} -> socket
        nil -> socket
        _other_wallet -> closed(socket)
      end

    case {signer, request(socket.assigns)} do
      {signer, {:ok, request}} when is_binary(signer) ->
        id = socket.assigns.current_human_id

        socket
        |> assign(refusal: nil)
        |> start_async(:quote, fn -> {request, signer, prepare(id, request, signer)} end)

      {_signer, _request} ->
        assign(socket, quote: nil, refusal: nil)
    end
    |> assign(mismatch: OnchainSteps.mismatch_note(socket.assigns.linked, socket.assigns.active))
    |> read_held()
  end

  # What the wallet the panel shows figures for holds, for the balance and Max:
  # read again for each new wallet and each ask (`held_reads`). A new ask stops
  # the read still running for an earlier one, so asks never stack.
  defp read_held(%{assigns: assigns} = socket) do
    wallet =
      if is_list(assigns.linked),
        do: OnchainSteps.shown_wallet(assigns.linked, assigns.signed_in, assigns.active)

    key = {wallet, assigns.held_reads}
    %{product: product, current_human_id: id} = assigns

    cond do
      key == assigns.held_for ->
        socket

      is_nil(wallet) ->
        socket |> cancel_async(:held) |> assign(held_for: key, held: nil)

      true ->
        socket
        |> assign(held_for: key)
        |> cancel_async(:held)
        |> start_async(:held, fn -> {key, held(product.id, id, wallet)} end)
    end
  end

  defp held(product, id, wallet) do
    case Earn.read_earn_position(product, %{wallet: wallet}, actor: %Human{human_account_id: id}) do
      {:ok, %{holding: holding}} -> holding
      {:error, _error} -> nil
    end
  end

  # The button: the steps for the amount as it stands, read again now. When the
  # chain makes the step certain to fail, it says why and nothing opens; an
  # approval still to send is a step of the review.
  defp reviewed(socket) do
    case {signer(socket), request(socket.assigns)} do
      {nil, _request} ->
        assign(socket, notice: no_signer(socket.assigns))

      {_signer, {:error, entry}} ->
        assign(socket, notice: entry_words(entry) || "Enter an amount above zero.")

      {signer, {:ok, request}} ->
        case prepare(socket.assigns.current_human_id, request, signer) do
          {:ok, %{blocked: nil} = prepared} ->
            # Each opening is its own review, so the same figures reviewed again
            # never show the presses of an earlier one.
            openings = socket.assigns.openings + 1

            review =
              Review.new(socket.assigns.id, signer, prepared.chain, prepared.steps, %{
                "opening" => Integer.to_string(openings)
              })

            socket
            |> assign(reviewed: prepared, landed: MapSet.new(), openings: openings)
            |> assign(notice: nil, press_note: nil, quote: {request, signer, prepared})
            |> OnchainSteps.put_review(review)

          {:ok, prepared} ->
            socket
            |> assign(quote: {request, signer, prepared})
            |> assign(notice: blocked_words(prepared.blocked) <> ".")

          {:error, reason} ->
            assign(socket, notice: refusal_words(reason))
        end
    end
  end

  defp no_signer(%{linked: nil}), do: "Sign in to use your wallet here."

  defp no_signer(%{linked: linked, active: active}),
    do: OnchainSteps.failure_note("wallet_unavailable", linked, active, "Base")

  # A step landed: the page reads the market again and the panel the wallet.
  # When every step of the open review has landed once, whichever press of it
  # landed, the review closes and the page says what moved.
  defp confirmed(socket, %{review: %{id: id}, name: name}) do
    send(self(), {:earn_changed, socket.assigns.product.id})
    socket = update(socket, :held_reads, &(&1 + 1))

    case socket.assigns.review do
      %{id: ^id} ->
        socket = assign(socket, landed: MapSet.put(socket.assigns.landed, name))

        if Enum.all?(steps(socket.assigns), &(&1.state == :done)),
          do: finished(socket),
          else: socket

      _other_review ->
        socket
    end
    |> sync()
  end

  # A step of the open review that did not go through: the step is reviewed
  # again at once from the chain as it is now (`OnchainSteps.rebuild_reverted/4`).
  defp step_reverted(socket, entry) do
    note = "The step did not go through and nothing moved."

    OnchainSteps.rebuild_reverted(socket, entry, note, fn socket ->
      socket |> closed() |> reviewed() |> OnchainSteps.rebuilt(note)
    end)
  end

  defp finished(socket) do
    %{reviewed: prepared, decimals: decimals} = socket.assigns
    send(self(), {:earn_done, %{kind: prepared.kind, lines: [done_line(prepared, decimals)]}})

    socket
    |> assign(text: "", max: false)
    |> closed()
  end

  defp closed(socket) do
    socket
    |> assign(reviewed: nil, landed: MapSet.new(), press_note: nil)
    |> OnchainSteps.put_review(nil)
  end

  defp prepare(id, request, signer) do
    case Earn.prepare_earn_steps(
           request.product,
           request.kind,
           request |> Map.drop([:product, :kind]) |> Map.put(:signer, signer),
           actor: %Human{human_account_id: id}
         ) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, Earn.reason(error)}
    end
  end

  defp signer(socket), do: OnchainSteps.signer(socket.assigns.linked, socket.assigns.active)

  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &sync/1)

  # The step the amount asks for: everything when Max asked for it on a
  # withdrawal, otherwise the amount typed, once it reads.
  defp request(%{kind: :withdraw, max: true, product: product}),
    do: {:ok, %{product: product.id, kind: :withdraw, everything: true}}

  defp request(%{kind: kind, text: text, decimals: decimals, product: product}) do
    case Amount.entry(text, decimals) do
      {:valid, units} -> {:ok, %{product: product.id, kind: kind, amount: units}}
      :empty -> {:error, :empty}
      {:invalid, reason} -> {:error, {:invalid, reason}}
    end
  end

  # The figures for the amount as it stands and the wallet that may act, once
  # the chain has been read for them.
  defp current(%{quote: {request, signer, prepared}} = assigns) do
    if {:ok, request} == request(assigns) and
         signer == OnchainSteps.signer(assigns.linked, assigns.active),
       do: prepared
  end

  defp current(_assigns), do: nil

  @impl true
  def render(assigns) do
    prepared = current(assigns)
    entry = if assigns.max, do: :empty, else: Amount.entry(assigns.text, assigns.decimals)

    assigns =
      assign(assigns,
        blocked: prepared && prepared.blocked && blocked_words(prepared.blocked),
        refused: assigns.refusal && refusal_words(assigns.refusal),
        entry_problem: entry_words(entry),
        steps: steps(assigns),
        next_step: next_step(assigns)
      )

    ~H"""
    <section id={@id} class="earn-panel" phx-hook="OnchainSteps" data-refresh-funds>
      <div
        id={"#{@id}-buttons"}
        class="token-swap__stack"
        phx-hook="SiteButtons"
        phx-mounted={JS.ignore_attributes("data-input")}
      >
        <div class="earn-panel__body" inert={!is_nil(@review)}>
          <dl :if={@linked != nil} id={"#{@id}-balance"} class="earn-panel__balance">
            <div>
              <dt>Balance</dt>
              <dd>{(@held && amount(@held.balance, @decimals, @product.asset)) || "—"}</dd>
            </div>
            <div>
              <dt>Wallet</dt>
              <dd>{(@held && amount(@held.usdc, @decimals, @product.asset)) || "—"}</dd>
            </div>
          </dl>
          <p :if={@held && @held.position == :none} class="earn-panel__muted">
            No balance yet. Deposit {@product.asset} to start earning.
          </p>
          <p :if={@linked == nil} class="earn-panel__muted">
            Sign in to see your balance and deposit.
          </p>

          <form
            id={"#{@id}-form"}
            class="earn-panel__form"
            phx-change="change"
            phx-submit="review"
            phx-target={@myself}
          >
            <div class="rg-field">
              <label for={"#{@id}-amount"}>Amount</label>
              <span class="earn-panel__input">
                <input
                  id={"#{@id}-amount"}
                  name="amount"
                  type="text"
                  value={@text}
                  inputmode="decimal"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder="0"
                  aria-describedby={"#{@id}-entry"}
                />
                <span aria-hidden="true">{@product.asset}</span>
                <button
                  :if={@held}
                  id={"#{@id}-max"}
                  type="button"
                  class="earn-panel__max"
                  phx-click="max"
                  phx-target={@myself}
                  aria-pressed={to_string(@max)}
                >
                  Max
                </button>
              </span>
            </div>
            <p :if={@max} class="earn-panel__muted">
              Withdraws your whole balance as it stands when the step lands, interest included.
            </p>
            <p id={"#{@id}-entry"} class="earn-panel__problem" role="status">{@entry_problem}</p>
            <p :if={@refused} class="earn-panel__problem" role="alert">{@refused}</p>
            <P.button
              :if={@linked != nil}
              id={"#{@id}-review"}
              type="submit"
              class="token-swap__submit"
              disabled={@blocked != nil}
              aria-describedby={@blocked && "#{@id}-why"}
              data-press="motion"
              phx-mounted={JS.ignore_attributes("style")}
            >
              <span class="site-glint" aria-hidden="true"></span>{action_label(@kind)}
            </P.button>
            <P.button
              :if={@linked == nil}
              type="button"
              class="token-swap__submit"
              data-account-target="sign-in"
            >
              Sign in
            </P.button>
            <p id={"#{@id}-why"} class="earn-panel__reason">{@blocked}</p>
            <p class="onchain-note" role="status" hidden={!@mismatch}>{@mismatch}</p>
            <p
              :if={@notice && is_nil(@review)}
              id={"#{@id}-notice"}
              class="token-swap__error"
              role="alert"
              phx-hook="MotionRefusal"
              data-refused
            >
              {@notice}
            </p>
          </form>
        </div>

        <StakeComponent.stake_review
          id={"#{@id}-review-panel"}
          open={!!@review}
          title={@reviewed && action_label(@reviewed.kind)}
          facts={(@reviewed && facts(@reviewed, @decimals)) || []}
          steps={@steps}
          next_step={@next_step}
          notice={@press_note}
          target={@myself}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
        />
      </div>

      <p class="earn-panel__problem" role="status" data-onchain-lost>
        <span>Connection lost. Nothing was sent.</span>
      </p>
    </section>
    """
  end

  attr :id, :string, required: true

  attr :done, :map,
    required: true,
    doc: "`%{kind: kind, lines: [String.t()]}` from `{:earn_done, done}`"

  attr :dismiss, :string, required: true, doc: "the event the dismiss button sends"

  @doc "What a confirmed deposit or withdrawal moved."
  def toast(assigns) do
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
        <p :for={line <- @done.lines}>{line}</p>
        <AutolaunchWeb.Components.PortfolioLink.portfolio_link />
      </div>
      <P.button
        type="button"
        variant="quiet"
        phx-click={@dismiss}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <Regent.Icons.icon name="x" class="dismiss-icon" />
      </P.button>
    </aside>
    """
  end

  @doc "An amount of the asset as every Earn figure shows it."
  def amount(units, decimals, asset),
    do: RegentFormat.token_amount(units, decimals) <> " " <> asset

  defp facts(%{kind: :deposit} = prepared, decimals) do
    [
      ["Amount", amount(prepared.units, decimals, prepared.product.asset)],
      ["Market", prepared.product.market],
      ["Rate now", Answer.yearly_percent(prepared.terms.rate) <> "% a year"]
    ]
  end

  defp facts(%{kind: :withdraw, withdrawal: :everything} = prepared, decimals) do
    [
      ["Amount", "All, #{amount(prepared.units, decimals, prepared.product.asset)} now"],
      ["Market", prepared.product.market],
      ["To", "This wallet"]
    ]
  end

  defp facts(%{kind: :withdraw} = prepared, decimals) do
    [
      ["Amount", amount(prepared.units, decimals, prepared.product.asset)],
      ["Market", prepared.product.market],
      ["To", "This wallet"]
    ]
  end

  defp done_line(%{kind: :deposit} = prepared, decimals),
    do:
      "#{amount(prepared.units, decimals, prepared.product.asset)} is earning in #{prepared.product.market}."

  defp done_line(%{kind: :withdraw, withdrawal: :everything}, _decimals),
    do: "Your whole balance is back in your wallet."

  defp done_line(%{kind: :withdraw} = prepared, decimals),
    do: "#{amount(prepared.units, decimals, prepared.product.asset)} is back in your wallet."

  defp steps(%{review: nil}), do: []

  # Where each step of the open review stands. An approval the chain already
  # held when the review was built shows as done; a press on it still sends.
  # A step one of whose presses landed is done, whatever a later press of it
  # does.
  defp steps(%{review: review, reviewed: prepared, presses: presses, landed: landed}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)

      state =
        cond do
          MapSet.member?(landed, name) -> :done
          step_state(entry) == :ready and name == "usdc_approval" and prepared.approved -> :done
          true -> step_state(entry)
        end

      %{name: name, label: step_label(name), state: state, entry: entry}
    end)
  end

  defp next_step(%{review: %{}} = assigns),
    do: Enum.find(steps(assigns), &(&1.state in [:ready, :reverted, :other]))

  defp next_step(_assigns), do: nil

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp step_label("usdc_approval"), do: "Approve USDC"
  defp step_label("supply"), do: "Confirm deposit"
  defp step_label("withdraw"), do: "Confirm withdrawal"

  defp action_label(:deposit), do: "Deposit"
  defp action_label(:withdraw), do: "Withdraw"

  defp done_title(:deposit), do: "Deposited"
  defp done_title(:withdraw), do: "Withdrawn"

  defp entry_words(:empty), do: nil
  defp entry_words({:valid, _units}), do: nil

  defp entry_words({:invalid, :not_a_number}),
    do: "Enter a number, with a dot for decimals (1.5)."

  defp entry_words({:invalid, :too_precise}), do: "USDC goes to six decimal places."
  defp entry_words({:invalid, :zero}), do: "Enter an amount above zero."
  defp entry_words({:invalid, :too_large}), do: "That amount is too large."

  defp blocked_words(:market_inactive), do: "This market is closed"
  defp blocked_words(:market_paused), do: "This market is paused"
  defp blocked_words(:market_frozen), do: "This market takes no deposits right now"
  defp blocked_words(:not_enough_usdc), do: "Not enough USDC on Base"
  defp blocked_words(:over_supply_cap), do: "More than the market takes right now"
  defp blocked_words(:over_balance), do: "More than your balance"
  defp blocked_words(:not_available_now), do: "Not that much is available to withdraw right now"

  defp refusal_words(:wrong_signer), do: "Use one of your account's own wallets."
  defp refusal_words(:invalid_amount), do: "Enter an amount above zero."
  defp refusal_words(_unavailable), do: "We couldn't reach Base just now. Try again in a moment."
end
