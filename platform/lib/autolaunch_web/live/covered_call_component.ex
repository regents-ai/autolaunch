defmodule AutolaunchWeb.CoveredCallComponent do
  @moduledoc """
  The wallet panel for one covered-call action: list calls, buy them, exercise,
  stop selling, collect stock or collect USDC, the way the token page's Stake
  and Claim and the Buy window work. The form shows what the action comes to
  as it is typed; its button opens a review over the form with the steps the
  wallet sends, one button at a time, and the review closes when the chain
  confirms the last one. The page then shows what moved (`toast/1`), from
  `{:covered_call_done, done}`: an action can take its own panel off the page
  (the last calls bought, a row's last collection).

  The server builds every step (`Autolaunch.CoveredCalls.prepare_covered_call/3`,
  the same action agents call) for the wallet that may act
  (`AutolaunchWeb.OnchainSteps`), and every press of the wallet button goes
  straight to the wallet. An approval is its own step; one the chain already
  holds shows as done. The form's button is disabled only when the chain, read
  at the latest block for the form as it stands, makes the action certain to
  fail, with the reason beside it.

  The page passes `kind`, `symbol`, `unit` (raw units per whole token), the
  `listing` an action is on, `expiries` for a new listing, `holding` for an
  exercise, the panel's `session_lease` and `current_human_id`, and, for a row
  of actions such as the portfolio's, `variant="secondary"` for its button. A landed
  step tells the page with `{:covered_calls_changed, symbol, press}`, `press`
  naming the listing and its seller (both `nil` for a new one) and the wallet
  that sent it.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Book, Terms}
  alias AutolaunchWeb.CoveredCallsFormat, as: F
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
       inputs: %{},
       quote: nil,
       refusal: nil,
       reviewed: nil,
       landed: MapSet.new(),
       openings: 0,
       typed: false,
       notice: nil,
       listing: nil,
       holding: nil,
       expiries: [],
       variant: "primary"
     )}
  end

  # A suggestion the page's guide offers, put into the form as if typed.
  @impl true
  def update(%{fill: fill}, socket),
    do:
      {:ok,
       socket
       |> assign(inputs: Map.merge(socket.assigns.inputs, fill), typed: true, notice: nil)
       |> tell_form()
       |> sync()}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Until the person types, the form follows the listing as the page reads it.
    socket =
      if socket.assigns.typed,
        do: socket,
        else: assign(socket, inputs: defaults(socket.assigns))

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
  # allows the action.
  def handle_event("refresh_funds", _params, socket), do: {:noreply, sync(socket)}

  def handle_event("change", params, socket) do
    socket = assign(socket, inputs: inputs(socket.assigns.kind, params), typed: true, notice: nil)
    {:noreply, socket |> tell_form() |> sync()}
  end

  # The form sends its fields with the press, so a figure typed a moment ago
  # is the one reviewed.
  def handle_event("review", params, socket) do
    socket =
      if socket.assigns.kind in [:list, :fill, :exercise] and is_map_key(params, "amount"),
        do: assign(socket, inputs: inputs(socket.assigns.kind, params), typed: true),
        else: socket

    {:noreply, reviewed(socket)}
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, socket |> OnchainSteps.sent(params) |> assign(notice: nil)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:covered_calls, reason)
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
  def handle_async(:quote, {:ok, {inputs, signer, result}}, socket) do
    if inputs == socket.assigns.inputs and signer == signer(socket) do
      case result do
        {:ok, prepared} ->
          {:noreply, assign(socket, quote: {inputs, signer, prepared}, refusal: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, quote: nil, refusal: reason)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:quote, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, quote: nil, refusal: :chain_unavailable)}

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  # The form's figures follow the wallet that may act and the form as it
  # stands. A review open for another wallet closes: its steps were built for
  # that wallet only.
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
        %{inputs: inputs} = socket.assigns
        assigns = Map.take(socket.assigns, [:symbol, :kind, :current_human_id])

        socket
        |> assign(refusal: nil)
        |> start_async(:quote, fn -> {inputs, signer, prepare(assigns, request, signer)} end)

      {_signer, request} ->
        refusal = if match?({:error, _}, request), do: elem(request, 1)
        assign(socket, quote: nil, refusal: refusal)
    end
    |> assign(mismatch: OnchainSteps.mismatch_note(socket.assigns.linked, socket.assigns.active))
  end

  # The form's button: the steps for the form as it stands, read again now.
  # When the chain makes the action certain to fail, it says why and nothing
  # opens; an approval still to send is a step of the review.
  defp reviewed(socket) do
    case {signer(socket), request(socket.assigns)} do
      {nil, _request} ->
        assign(socket, notice: no_signer(socket.assigns))

      {_signer, {:error, reason}} ->
        assign(socket, notice: refusal_words(reason) || unreadable(socket.assigns.kind))

      {signer, {:ok, request}} ->
        case prepare(socket.assigns, request, signer) do
          {:ok, %{blocked: blocked} = prepared} when blocked in [nil, :approve_first] ->
            # Each opening is its own review, so the same figures reviewed again
            # never show the presses of an earlier one.
            openings = socket.assigns.openings + 1

            review =
              Review.new(socket.assigns.id, signer, prepared.chain, prepared.steps, %{
                "opening" => Integer.to_string(openings)
              })

            socket
            |> assign(reviewed: prepared, landed: MapSet.new(), openings: openings)
            |> assign(
              notice: nil,
              press_note: nil,
              quote: {socket.assigns.inputs, signer, prepared}
            )
            |> OnchainSteps.put_review(review)

          {:ok, prepared} ->
            socket
            |> assign(quote: {socket.assigns.inputs, signer, prepared})
            |> assign(notice: blocked_words(prepared.blocked, socket.assigns) <> ".")

          {:error, reason} ->
            assign(socket, notice: refusal_words(reason) || unreadable(socket.assigns.kind))
        end
    end
  end

  # A form whose figures don't read: what each figure takes.
  defp unreadable(:list),
    do: "Enter an amount above zero and prices to the cent, with a dot for decimals (1.50)."

  defp unreadable(_kind), do: "Enter an amount above zero, with a dot for decimals (1.5)."

  # The List form tells the page what it holds, so the page's guide follows it.
  defp tell_form(%{assigns: %{kind: :list, inputs: inputs}} = socket) do
    send(self(), {:covered_call_form, inputs})
    socket
  end

  defp tell_form(socket), do: socket

  defp no_signer(%{linked: nil}), do: "Sign in to use your wallet here."

  defp no_signer(%{linked: linked, active: active}),
    do: OnchainSteps.failure_note("wallet_unavailable", linked, active, "Base")

  # A step landed: the page reads the market again. When every step of the
  # open review has landed once, whichever press of it landed, the review
  # closes and the page says what moved.
  defp confirmed(socket, %{review: %{id: id, signer: signer}, name: name}) do
    Book.expire(socket.assigns.symbol)

    send(
      self(),
      {:covered_calls_changed, socket.assigns.symbol,
       %{
         listing_id: socket.assigns.listing[:id],
         seller: socket.assigns.listing[:seller],
         wallet: signer
       }}
    )

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

  defp finished(socket) do
    %{kind: kind, reviewed: prepared} = socket.assigns

    send(
      self(),
      {:covered_call_done, %{kind: kind, lines: done_lines(kind, prepared.facts, socket.assigns)}}
    )

    socket
    |> assign(cleared(kind, socket.assigns))
    |> tell_form()
    |> closed()
  end

  defp closed(socket) do
    socket
    |> assign(reviewed: nil, landed: MapSet.new(), press_note: nil)
    |> OnchainSteps.put_review(nil)
  end

  defp prepare(assigns, request, signer) do
    actor = %Human{human_account_id: assigns.current_human_id}

    case CoveredCalls.prepare_covered_call(
           assigns.symbol,
           assigns.kind,
           Map.put(request, :signer, signer),
           actor: actor
         ) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, CoveredCalls.reason(error)}
    end
  end

  defp signer(socket), do: OnchainSteps.signer(socket.assigns.linked, socket.assigns.active)

  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &sync/1)

  # The typed form, as the arguments of the action.
  defp request(%{kind: :list, inputs: inputs, unit: unit}) do
    with {:ok, amount} <- amount(F.parse_tokens(inputs["amount"], unit)),
         {:ok, strike} <- amount(F.parse_usd(inputs["strike"])),
         {:ok, premium} <- amount(F.parse_usd(inputs["premium"])),
         {expiry, ""} <- Integer.parse(inputs["expiry"] || "") do
      {:ok,
       %{amount: amount, strike_per_token: strike, premium_per_token: premium, expiry: expiry}}
    else
      {:error, _reason} = error -> error
      _no_expiry -> {:error, :not_a_weekly_expiry}
    end
  end

  defp request(%{kind: kind, inputs: inputs, unit: unit, listing: listing})
       when kind in [:fill, :exercise] do
    with {:ok, amount} <- amount(F.parse_tokens(inputs["amount"], unit)),
         do: {:ok, %{listing_id: listing.id, amount: amount}}
  end

  defp request(%{listing: listing}), do: {:ok, %{listing_id: listing.id}}

  defp amount(nil), do: {:error, :invalid_amount}
  defp amount(value), do: {:ok, value}

  defp inputs(:list, form), do: Map.take(form, ~w(amount strike premium expiry))
  defp inputs(kind, form) when kind in [:fill, :exercise], do: Map.take(form, ~w(amount))
  defp inputs(_kind, _form), do: %{}

  defp defaults(%{kind: :list, expiries: [first | _]}),
    do: %{"amount" => "", "strike" => "", "premium" => "", "expiry" => Integer.to_string(first)}

  defp defaults(%{kind: :exercise, listing: listing, unit: unit, holding: held}),
    do: %{"amount" => F.tokens(held || listing.filled, unit)}

  defp defaults(%{kind: :fill, listing: listing, unit: unit}),
    do: %{"amount" => F.tokens(listing.amount - listing.filled, unit)}

  defp defaults(_assigns), do: %{}

  # A new listing starts empty again on the same expiry; the other forms
  # follow the listing again as the page reads it next (`update/2`).
  defp cleared(:list, %{inputs: inputs}),
    do: [
      inputs: %{"amount" => "", "strike" => "", "premium" => "", "expiry" => inputs["expiry"]},
      typed: true
    ]

  defp cleared(_kind, assigns), do: [inputs: defaults(assigns), typed: false]

  defp approval?(name), do: name in ~w(stock_approval usdc_approval)

  # The figures for the form as it stands and the wallet that may act, once the
  # chain has been read for them.
  defp current(%{quote: {inputs, signer, prepared}, inputs: inputs} = assigns) do
    if signer == OnchainSteps.signer(assigns.linked, assigns.active), do: prepared
  end

  defp current(_assigns), do: nil

  @impl true
  def render(assigns) do
    prepared = current(assigns)

    assigns =
      assign(assigns,
        prepared: prepared,
        blocked: prepared && blocked_words(prepared.blocked, assigns),
        refused: refusal_words(assigns.refusal),
        steps: steps(assigns),
        next_step: next_step(assigns)
      )

    ~H"""
    <section id={@id} class="covered-call-panel" phx-hook="OnchainSteps" data-refresh-funds>
      <div
        id={"#{@id}-buttons"}
        class="token-swap__stack"
        phx-hook="SiteButtons"
        phx-mounted={JS.ignore_attributes("data-input")}
      >
        <div class="covered-call-panel__body" inert={!is_nil(@review)}>
          <form
            :if={@kind in [:list, :fill, :exercise]}
            id={"#{@id}-form"}
            class="covered-call-panel__form"
            phx-change="change"
            phx-submit="review"
            phx-target={@myself}
          >
            <.list_fields
              :if={@kind == :list}
              id={@id}
              inputs={@inputs}
              expiries={@expiries}
              symbol={@symbol}
            />
            <.field
              :if={@kind in [:fill, :exercise]}
              id={"#{@id}-amount"}
              name="amount"
              label="Amount"
              value={@inputs["amount"]}
              unit={@symbol}
            />
            <.action {action_assigns(assigns)} type="submit" />
          </form>
          <.action
            :if={@kind not in [:list, :fill, :exercise]}
            {action_assigns(assigns)}
            type="button"
          />
        </div>

        <StakeComponent.stake_review
          id={"#{@id}-review-panel"}
          open={!!@review}
          title={@reviewed && title(@kind)}
          facts={(@reviewed && facts(@kind, @reviewed.facts, assigns)) || []}
          steps={@steps}
          next_step={@next_step}
          reverted={reverted(@steps, @kind)}
          notice={@press_note}
          target={@myself}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
        />
      </div>

      <p class="token-swap__error" role="status" data-onchain-lost hidden>
        This page lost its connection, so nothing was sent. Press again once it's back.
      </p>
    </section>
    """
  end

  defp action_assigns(assigns) do
    Map.take(assigns, [
      :id,
      :variant,
      :kind,
      :symbol,
      :unit,
      :prepared,
      :blocked,
      :refused,
      :notice,
      :review,
      :linked,
      :mismatch,
      :myself
    ])
  end

  attr :id, :string, required: true
  attr :type, :string, required: true
  attr :kind, :atom, required: true
  attr :symbol, :string, required: true
  attr :unit, :integer, required: true
  attr :prepared, :map, default: nil
  attr :blocked, :string, default: nil
  attr :refused, :string, default: nil
  attr :notice, :string, default: nil
  attr :review, :map, default: nil
  attr :linked, :any, required: true
  attr :mismatch, :any, default: nil
  attr :variant, :string, default: "primary"
  attr :myself, :any, required: true

  # What the action comes to, and the button that reviews it: a submit inside
  # the form, so the press carries every field as typed, or a plain button
  # where there is nothing to type. Neither sends anything to the wallet.
  defp action(assigns) do
    ~H"""
    <dl :if={@prepared} class="covered-call-panel__facts">
      <div :for={[label, value] <- facts(@kind, @prepared.facts, assigns)}>
        <dt>{label}</dt>
        <dd>{value}</dd>
      </div>
    </dl>
    <p :if={@refused} class="covered-call-panel__problem" role="alert">{@refused}</p>
    <P.button
      :if={@linked != nil}
      id={"#{@id}-review"}
      type={@type}
      variant={@variant}
      class="token-swap__submit"
      phx-click={@type == "button" && "review"}
      phx-target={@type == "button" && @myself}
      disabled={@blocked != nil}
      aria-describedby={@blocked && "#{@id}-why"}
      data-press="motion"
      phx-mounted={JS.ignore_attributes("style")}
    >
      <span class="site-glint" aria-hidden="true"></span>{action_label(@kind, @symbol)}
    </P.button>
    <P.button
      :if={@linked == nil}
      type="button"
      class="token-swap__submit"
      data-account-target="sign-in"
    >
      Sign in
    </P.button>
    <p :if={@blocked} id={"#{@id}-why"} class="covered-call-panel__reason">{@blocked}</p>
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
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :unit, :string, required: true

  defp field(assigns) do
    ~H"""
    <div class="rg-field">
      <label for={@id}>{@label}</label>
      <span class="covered-call-panel__input">
        <input
          id={@id}
          name={@name}
          type="text"
          value={@value}
          inputmode="decimal"
          autocomplete="off"
          spellcheck="false"
          placeholder="0"
        />
        <span aria-hidden="true">{@unit}</span>
      </span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :inputs, :map, required: true
  attr :expiries, :list, required: true
  attr :symbol, :string, required: true

  defp list_fields(assigns) do
    ~H"""
    <.field
      id={"#{@id}-amount"}
      name="amount"
      label="Amount"
      value={@inputs["amount"]}
      unit={@symbol}
    />
    <.field
      id={"#{@id}-strike"}
      name="strike"
      label="Strike price"
      value={@inputs["strike"]}
      unit={"USDC per #{@symbol}"}
    />
    <div class="rg-field">
      <label for={"#{@id}-expiry"}>Exercise window</label>
      <span class="covered-call-panel__input">
        <select id={"#{@id}-expiry"} name="expiry" aria-describedby={"#{@id}-expiry-hint"}>
          <option
            :for={expiry <- @expiries}
            value={expiry}
            selected={Integer.to_string(expiry) == @inputs["expiry"]}
          >
            {F.window_days(expiry)}
          </option>
        </select>
      </span>
      <small id={"#{@id}-expiry-hint"} class="covered-call-panel__hint">
        Opens Friday 21:00 UTC, closes Saturday 21:00 UTC.
      </small>
    </div>
    <.field
      id={"#{@id}-premium"}
      name="premium"
      label="Premium"
      value={@inputs["premium"]}
      unit={"USDC per #{@symbol}"}
    />
    """
  end

  attr :id, :string, required: true

  attr :done, :map,
    required: true,
    doc: "`%{kind: kind, lines: [String.t()]}` from `{:covered_call_done, done}`"

  attr :dismiss, :string, required: true, doc: "the event the dismiss button sends"
  attr :target, :any, default: nil

  @doc "What a confirmed action moved, as the token page's Stake says it."
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
      </div>
      <P.button
        type="button"
        variant="quiet"
        phx-click={@dismiss}
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" aria-hidden="true">
          <path
            d="M6 6l12 12M18 6 6 18"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
          />
        </svg>
      </P.button>
    </aside>
    """
  end

  # What the action comes to, as label and value, in the form and its review.
  defp facts(:list, facts, %{unit: unit, symbol: symbol}) do
    premium = F.total(facts.amount, facts.premium_per_token, unit)

    [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Strike", "#{F.usd(facts.strike_per_token)} per #{symbol}"],
      ["Exercise window", F.window(facts.expiry)],
      ["Total premium", F.usd(premium)],
      ["You receive", "#{F.usd(premium - Terms.fee(premium))} if all sell, after the 1% fee"],
      ["Total at strike", F.usd(F.total(facts.amount, facts.strike_per_token, unit))]
    ]
  end

  defp facts(:fill, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Premium", F.usd_due(facts.premium)],
      ["Exercise cost", F.usd_due(facts.strike)],
      ["Exercise window", F.window(facts.expiry)]
    ]

  defp facts(:exercise, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["You pay", F.usd_due(facts.strike)],
      ["To collect", "#{F.tokens(facts.amount, unit)} #{symbol}"]
    ]

  # Nothing to collect or stop is said once, as the button's reason, not as a zero.
  defp facts(kind, %{amount: 0}, _assigns) when kind in [:claim, :collect_strike], do: []
  defp facts(:cancel, %{unsold: 0}, _assigns), do: []

  defp facts(:claim, facts, %{unit: unit, symbol: symbol}),
    do: [["You receive", "#{F.tokens(facts.amount, unit)} #{symbol}"]]

  defp facts(:collect_strike, facts, _assigns), do: [["You receive", F.usd(facts.amount)]]

  defp facts(:cancel, facts, %{unit: unit, symbol: symbol}),
    do: [["Unsold", "#{F.tokens(facts.unsold, unit)} #{symbol}"]]

  defp done_lines(:list, facts, %{unit: unit, symbol: symbol}),
    do: [
      "#{F.tokens(facts.amount, unit)} #{symbol} at #{F.usd(facts.strike_per_token)}, #{F.window_days(facts.expiry)}"
    ]

  defp done_lines(:fill, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.amount, unit)} #{symbol} of calls for #{F.usd_due(facts.premium)}"]

  defp done_lines(:exercise, facts, %{unit: unit, symbol: symbol}),
    do: [
      "#{F.tokens(facts.amount, unit)} #{symbol} for #{F.usd_due(facts.strike)}, ready to collect"
    ]

  defp done_lines(:claim, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.amount, unit)} #{symbol}"]

  defp done_lines(:collect_strike, facts, _assigns), do: [F.usd(facts.amount)]

  defp done_lines(:cancel, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.unsold, unit)} #{symbol} unsold, ready to collect"]

  defp steps(%{review: nil}), do: []

  # Where each step of the open review stands. An approval the chain already
  # held when the review was built shows as done; a press on it still sends.
  # A step one of whose presses landed is done, whatever a later press of it
  # does.
  defp steps(%{review: review, reviewed: prepared, presses: presses, landed: landed} = assigns) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)

      state =
        cond do
          MapSet.member?(landed, name) -> :done
          step_state(entry) == :ready and approval?(name) and prepared.approved -> :done
          true -> step_state(entry)
        end

      %{name: name, label: step_label(name, assigns), state: state, entry: entry}
    end)
  end

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. A sent step moves the button on
  # at once; nothing waits for the network before the next press can reach the
  # wallet.
  defp next_step(%{review: %{}} = assigns),
    do: Enum.find(steps(assigns), &(&1.state in [:ready, :reverted, :other]))

  defp next_step(_assigns), do: nil

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp reverted(steps, kind) do
    if Enum.any?(steps, &(&1.state == :reverted)), do: reverted_copy(kind)
  end

  defp reverted_copy(:fill),
    do:
      "The purchase did not go through and nothing moved. Someone may have bought these first: close this and review again."

  defp reverted_copy(_kind),
    do: "That did not go through and nothing moved. Close this and review again."

  defp action_label(:list, _symbol), do: "List calls"
  defp action_label(:fill, _symbol), do: "Buy calls"
  defp action_label(:exercise, _symbol), do: "Exercise"
  defp action_label(:cancel, _symbol), do: "Stop selling"
  defp action_label(:claim, symbol), do: "Collect #{symbol}"
  defp action_label(:collect_strike, _symbol), do: "Collect USDC"

  defp step_label("stock_approval", %{symbol: symbol}), do: "Approve #{symbol}"
  defp step_label("usdc_approval", _assigns), do: "Approve USDC"
  defp step_label("list", _assigns), do: "Confirm listing"
  defp step_label("fill", _assigns), do: "Confirm purchase"
  defp step_label("exercise", _assigns), do: "Confirm exercise"
  defp step_label("cancel", _assigns), do: "Confirm stop"
  defp step_label(name, _assigns) when name in ~w(claim collect_strike), do: "Confirm collection"

  defp title(:list), do: "You’re listing"
  defp title(:fill), do: "You’re buying"
  defp title(:exercise), do: "You’re exercising"
  defp title(:cancel), do: "You’re stopping sales"
  defp title(kind) when kind in [:claim, :collect_strike], do: "You’re collecting"

  defp done_title(:list), do: "Listed"
  defp done_title(:fill), do: "Bought"
  defp done_title(:exercise), do: "Exercised"
  defp done_title(:cancel), do: "Stopped"
  defp done_title(kind) when kind in [:claim, :collect_strike], do: "Collected"

  # An approval still to send is a step of the review, never a reason to stop.
  defp blocked_words(blocked, _assigns) when blocked in [nil, :approve_first], do: nil

  defp blocked_words(:not_enough_stock, %{symbol: symbol}),
    do: "Not enough #{symbol} in this wallet"

  defp blocked_words(:not_enough_usdc, _assigns), do: "Not enough USDC on Base"

  defp blocked_words(:corporate_action, _assigns),
    do: "A split or dividend is scheduled before this expiry"

  defp blocked_words(:fills_closed, _assigns), do: "Sales closed at expiry"
  defp blocked_words(:sold_out, _assigns), do: "Not that many left"

  defp blocked_words(:exercise_not_open, %{listing: listing}),
    do: "Opens #{F.expiry(listing.expiry)}"

  defp blocked_words(:exercise_closed, _assigns), do: "Window closed"

  defp blocked_words(:more_than_held, _assigns), do: "More than you hold"
  defp blocked_words(:not_seller, _assigns), do: "Only the seller's wallet can do this"
  defp blocked_words(:nothing_to_cancel, _assigns), do: "Nothing left to stop"
  defp blocked_words(:nothing_to_claim, _assigns), do: "Nothing to collect yet"
  defp blocked_words(:nothing_to_collect, _assigns), do: "No USDC to collect yet"

  defp refusal_words(nil), do: nil
  defp refusal_words(:invalid_amount), do: nil
  defp refusal_words(:not_a_weekly_expiry), do: "Choose one of the Friday expiries."
  defp refusal_words(:expiry_passed), do: "That expiry has passed. Choose a later Friday."
  defp refusal_words(:unknown_listing), do: "This listing isn't on Base."
  defp refusal_words(:wrong_signer), do: "Use one of your account's own wallets."
  defp refusal_words(_unavailable), do: "Base couldn't be read just now. Try again in a moment."
end
