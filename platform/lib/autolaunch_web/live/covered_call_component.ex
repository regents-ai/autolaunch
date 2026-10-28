defmodule AutolaunchWeb.CoveredCallComponent do
  @moduledoc """
  The wallet panel for one covered-call action: list calls, buy them, exercise,
  stop selling, collect stock or collect USDC. The server builds every step
  (`Autolaunch.CoveredCalls.prepare_covered_call/3`, the same action agents
  call) for the wallet that may act (`AutolaunchWeb.OnchainSteps`), and every
  press goes straight to the wallet.

  An approval is its own step and stays pressable once done. The action is
  disabled only when the chain, read at the latest block for this panel, makes
  it certain to fail, with the reason beside it; a press made before a new
  amount reached the server asks for the matching steps first.

  The page passes `kind`, `symbol`, `unit` (raw units per whole token), the
  `listing` an action is on, `expiries` for a new listing, and the panel's
  `session_lease` and `current_human_id`. A landed step tells the page with
  `{:covered_calls_changed, symbol}`.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.CoveredCalls
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.OnchainSteps
  alias Regent.Primitives, as: P
  alias RegentChain.Review

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> Session.check_component_lease(&take_account/2)
     |> OnchainSteps.init()
     |> assign(
       inputs: %{},
       prepared: nil,
       refusal: nil,
       wallet_for: nil,
       listing: nil,
       expiries: []
     )}
  end

  @impl true
  def update(%{refresh_review: _id}, socket), do: {:ok, sync(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.inputs == %{},
        do: assign(socket, inputs: defaults(socket.assigns)),
        else: socket

    {:ok, socket |> OnchainSteps.adopt() |> sync()}
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, socket |> assign(active: OnchainSteps.active_wallet(params)) |> sync()}

  def handle_event("change", params, socket),
    do: {:noreply, socket |> assign(inputs: inputs(socket.assigns.kind, params)) |> sync()}

  def handle_event("prepare_and_send", %{"form" => form, "step" => name}, socket)
      when is_map(form) and is_binary(name) do
    socket = assign(socket, inputs: inputs(socket.assigns.kind, form))

    with signer when is_binary(signer) <- signer(socket),
         {:ok, request} <- request(socket.assigns),
         {:ok, prepared} <- prepare(socket.assigns, request, signer) do
      socket = put_prepared(socket, signer, prepared)

      if action_step?(name) and prepared.blocked,
        do: {:reply, %{}, socket},
        else: {:reply, %{review: socket.assigns.review, send: name}, socket}
    else
      _nothing_to_send -> {:reply, %{}, sync(socket)}
    end
  end

  def handle_event("step_sent", params, socket), do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", %{"reason" => reason}, socket) when is_binary(reason) do
    %{linked: linked, active: active} = socket.assigns

    {:noreply,
     assign(socket, press_note: OnchainSteps.failure_note(reason, linked, active, "Base"))}
  end

  def handle_event("check_again", %{"hash" => hash}, socket),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  @impl true
  def handle_async(:prepare, {:ok, {inputs, signer, result}}, socket) do
    if inputs == socket.assigns.inputs and signer == signer(socket) do
      case result do
        {:ok, prepared} ->
          {:noreply, socket |> put_prepared(signer, prepared) |> OnchainSteps.refresh_later()}

        {:error, reason} ->
          {:noreply,
           socket |> assign(prepared: nil, refusal: reason) |> OnchainSteps.put_review(nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:prepare, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, refusal: :chain_unavailable)}

  def handle_async({:onchain_step, hash}, result, socket) do
    {:noreply,
     OnchainSteps.checked(socket, hash, result, fn socket, _entry ->
       send(self(), {:covered_calls_changed, socket.assigns.symbol})
       sync(socket)
     end)}
  end

  # The steps follow the wallet that may act and the form as it stands.
  defp sync(socket) do
    case {signer(socket), request(socket.assigns)} do
      {signer, {:ok, request}} when is_binary(signer) ->
        %{inputs: inputs} = socket.assigns
        assigns = socket.assigns

        socket
        |> assign(refusal: nil)
        |> start_async(:prepare, fn -> {inputs, signer, prepare(assigns, request, signer)} end)

      {_signer, request} ->
        refusal = if match?({:error, _}, request), do: elem(request, 1)

        socket
        |> assign(prepared: nil, refusal: refusal)
        |> OnchainSteps.put_review(nil)
    end
    |> assign(mismatch: OnchainSteps.mismatch_note(socket.assigns.linked, socket.assigns.active))
  end

  defp put_prepared(socket, signer, prepared) do
    review =
      Review.new(socket.assigns.id, signer, prepared.chain, prepared.steps, socket.assigns.inputs)

    socket
    |> assign(prepared: prepared, refusal: nil)
    |> OnchainSteps.put_review(review)
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

  defp defaults(%{kind: kind, listing: listing, unit: unit, holding: held})
       when kind == :exercise,
       do: %{"amount" => F.tokens(held || listing.filled, unit)}

  defp defaults(%{kind: :fill, listing: listing, unit: unit}),
    do: %{"amount" => F.tokens(listing.amount - listing.filled, unit)}

  defp defaults(_assigns), do: %{}

  defp action_step?(name), do: name not in ~w(stock_approval usdc_approval)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        steps: steps(assigns),
        blocked: assigns.prepared && blocked_words(assigns.prepared.blocked, assigns),
        refused: refusal_words(assigns.refusal)
      )

    ~H"""
    <section id={@id} class="covered-call-panel" phx-hook="OnchainSteps" data-onchain-prepare>
      <form
        :if={@kind in [:list, :fill, :exercise]}
        id={"#{@id}-form"}
        class="covered-call-panel__form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <.list_fields
          :if={@kind == :list}
          id={@id}
          inputs={@inputs}
          expiries={@expiries}
          symbol={@symbol}
        />
        <label :if={@kind in [:fill, :exercise]} class="covered-call-panel__field">
          <span>Amount</span>
          <span class="covered-call-panel__input">
            <input
              name="amount"
              value={@inputs["amount"]}
              inputmode="decimal"
              autocomplete="off"
              data-onchain-input="amount"
            />
            <span aria-hidden="true">{@symbol}</span>
          </span>
        </label>
      </form>

      <dl :if={@prepared} class="covered-call-panel__facts">
        <.facts kind={@kind} facts={@prepared.facts} unit={@unit} symbol={@symbol} />
      </dl>

      <p :if={@refused} class="covered-call-panel__problem" role="alert">{@refused}</p>
      <p class="covered-call-panel__note" hidden={!@mismatch}>{@mismatch}</p>

      <ol class="covered-call-panel__steps">
        <li :for={step <- @steps} class="covered-call-panel__step" data-state={step.state}>
          <P.button
            variant={if step.approval?, do: "secondary", else: nil}
            data-onchain-step={step.name}
            disabled={!step.approval? and @blocked != nil}
            aria-describedby={(!step.approval? and @blocked) && "#{@id}-why"}
          >
            <span data-press-label>{step.label}</span>
          </P.button>
          <div class="covered-call-panel__step-words">
            <span :if={step.words}>{step.words}</span>
            <span :if={!step.approval? and @blocked} id={"#{@id}-why"}>{@blocked}</span>
          </div>
          <P.button
            :if={step.stalled?}
            variant="quiet"
            phx-click="check_again"
            phx-value-hash={step.entry.hash}
            phx-target={@myself}
          >
            Check again
          </P.button>
        </li>
      </ol>

      <p :if={@press_note} class="covered-call-panel__note" role="status">{@press_note}</p>
      <p class="covered-call-panel__note" role="status" data-onchain-lost hidden>
        Connection lost, so nothing was sent. Press again once it's back.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :inputs, :map, required: true
  attr :expiries, :list, required: true
  attr :symbol, :string, required: true

  defp list_fields(assigns) do
    ~H"""
    <label class="covered-call-panel__field">
      <span>Amount to lock</span>
      <span class="covered-call-panel__input">
        <input
          name="amount"
          value={@inputs["amount"]}
          inputmode="decimal"
          autocomplete="off"
          data-onchain-input="amount"
        />
        <span aria-hidden="true">{@symbol}</span>
      </span>
    </label>
    <label class="covered-call-panel__field">
      <span>Strike price</span>
      <span class="covered-call-panel__input">
        <input
          name="strike"
          value={@inputs["strike"]}
          inputmode="decimal"
          autocomplete="off"
          data-onchain-input="strike"
        />
        <span aria-hidden="true">USDC per {@symbol}</span>
      </span>
    </label>
    <label class="covered-call-panel__field">
      <span>Expiry</span>
      <select name="expiry" data-onchain-input="expiry">
        <option
          :for={expiry <- @expiries}
          value={expiry}
          selected={Integer.to_string(expiry) == @inputs["expiry"]}
        >
          {F.expiry(expiry)}
        </option>
      </select>
    </label>
    <label class="covered-call-panel__field">
      <span>Premium</span>
      <span class="covered-call-panel__input">
        <input
          name="premium"
          value={@inputs["premium"]}
          inputmode="decimal"
          autocomplete="off"
          data-onchain-input="premium"
        />
        <span aria-hidden="true">USDC per {@symbol}</span>
      </span>
    </label>
    """
  end

  attr :kind, :atom, required: true
  attr :facts, :map, required: true
  attr :unit, :integer, required: true
  attr :symbol, :string, required: true

  defp facts(%{kind: :list} = assigns) do
    ~H"""
    <dt>Premium if every call sells</dt>
    <dd>{F.usd(F.total(@facts.amount, @facts.premium_per_token, @unit))}</dd>
    <dt>Sale price if exercised</dt>
    <dd>{F.usd(F.total(@facts.amount, @facts.strike_per_token, @unit))}</dd>
    """
  end

  defp facts(%{kind: :fill} = assigns) do
    ~H"""
    <dt>You pay</dt>
    <dd>{F.usd(@facts.premium)}</dd>
    """
  end

  defp facts(%{kind: :exercise} = assigns) do
    ~H"""
    <dt>You pay</dt>
    <dd>{F.usd(@facts.strike)}</dd>
    <dt>You receive</dt>
    <dd>{F.tokens(@facts.amount, @unit)} {@symbol}</dd>
    """
  end

  defp facts(%{kind: :claim} = assigns) do
    ~H"""
    <dt>Ready to collect</dt>
    <dd>{F.tokens(@facts.amount, @unit)} {@symbol}</dd>
    """
  end

  defp facts(%{kind: :collect_strike} = assigns) do
    ~H"""
    <dt>Ready to collect</dt>
    <dd>{F.usd(@facts.amount)}</dd>
    """
  end

  defp facts(%{kind: :cancel} = assigns) do
    ~H"""
    <dt>Unsold</dt>
    <dd>{F.tokens(@facts.unsold, @unit)} {@symbol}</dd>
    """
  end

  # The steps shown before any review exists name the same buttons, so a
  # first press still has something to press.
  defp steps(%{kind: kind, review: review, presses: presses, prepared: prepared} = assigns) do
    kind
    |> step_names()
    |> Enum.map(fn name ->
      entry = review && OnchainSteps.entry(presses, review, name)
      described = entry && OnchainSteps.describe(entry, "Base")
      approval? = not action_step?(name)

      %{
        name: name,
        label: label(name, assigns),
        approval?: approval?,
        state: step_state(described, approval?, prepared),
        words: described && described.state != :confirmed && described.words,
        entry: entry,
        stalled?: described && described.state == :stalled
      }
    end)
  end

  # A sent step shows how it went; before any press, an approval the chain
  # already holds shows as done and stays pressable.
  defp step_state(%{state: state}, _approval?, _prepared) when state in [:pending, :stalled],
    do: :pending

  defp step_state(%{state: :confirmed}, _approval?, _prepared), do: :done
  defp step_state(%{}, _approval?, _prepared), do: :failed
  defp step_state(_unsent, true, %{approved: true}), do: :done
  defp step_state(_unsent, _approval?, _prepared), do: :ready

  defp step_names(:list), do: ~w(stock_approval list)
  defp step_names(:fill), do: ~w(usdc_approval fill)
  defp step_names(:exercise), do: ~w(usdc_approval exercise)
  defp step_names(kind), do: [Atom.to_string(kind)]

  defp label("stock_approval", %{symbol: symbol}), do: "Approve #{symbol}"
  defp label("usdc_approval", _assigns), do: "Approve USDC"
  defp label("list", _assigns), do: "List calls"
  defp label("fill", _assigns), do: "Buy calls"
  defp label("exercise", _assigns), do: "Exercise"
  defp label("cancel", _assigns), do: "Stop selling"
  defp label("claim", %{symbol: symbol}), do: "Collect #{symbol}"
  defp label("collect_strike", _assigns), do: "Collect USDC"

  defp blocked_words(nil, _assigns), do: nil
  defp blocked_words(:approve_first, _assigns), do: "Approve first"

  defp blocked_words(:not_enough_stock, %{symbol: symbol}),
    do: "Not enough #{symbol} in this wallet"

  defp blocked_words(:not_enough_usdc, _assigns), do: "Not enough USDC on Base"

  defp blocked_words(:corporate_action, _assigns),
    do: "A split or dividend is scheduled before this expiry"

  defp blocked_words(:fills_closed, _assigns), do: "Sales closed at expiry"
  defp blocked_words(:sold_out, _assigns), do: "Not that many left"

  defp blocked_words(:outside_exercise_window, %{listing: listing}),
    do: "Exercise is open from #{F.expiry(listing.expiry)} to #{F.window_closes(listing.expiry)}"

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
  defp refusal_words(:wrong_signer), do: nil
  defp refusal_words(_unavailable), do: "Base couldn't be read just now. Try again in a moment."
end
