defmodule AutolaunchWeb.ExposureComponent do
  @moduledoc """
  The wallet panel for one Exposure action: mint a pair, return legs for the
  stock, record and apply the next price, or end a series whose price can no
  longer be recorded. The server builds every step
  (`Autolaunch.Exposure.prepare_exposure/4`, the same action agents call) for
  the wallet that may act (`AutolaunchWeb.OnchainSteps`), and every press goes
  straight to the wallet.

  An approval is its own step and stays pressable once done. The action is
  disabled only when the chain, read at the latest block for this panel, makes
  it certain to fail, with the reason beside it; a press made before a new
  amount reached the server asks for the matching steps first.

  The page passes `kind`, the `series` reading, and the panel's
  `session_lease` and `current_human_id`. A landed step tells the page with
  `{:exposure_changed, series_address}`.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Exposure
  alias AutolaunchWeb.ExposureFormat, as: F
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
     |> assign(inputs: %{}, prepared: nil, refusal: nil, unsent: false, holdings: nil)}
  end

  @impl true
  def update(%{refresh_review: _id}, socket), do: {:ok, sync(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, socket |> OnchainSteps.adopt() |> sync()}
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, socket |> assign(active: OnchainSteps.active_wallet(params)) |> sync()}

  def handle_event("change", params, socket),
    do: {:noreply, socket |> assign(inputs: inputs(socket.assigns.kind, params)) |> sync()}

  def handle_event("max", _params, %{assigns: %{holdings: holdings}} = socket)
      when is_map(holdings),
      do: {:noreply, socket |> assign(inputs: filled(socket.assigns, holdings)) |> sync()}

  def handle_event("max", _params, socket), do: {:noreply, socket}

  # A press made before the panel holds steps for the form as pressed: the steps
  # are built now and the pressed one handed back to send. When they can't be
  # (the chain unreadable just now, or a form that doesn't read as an amount),
  # the panel says so and nothing is sent; the page's follow-up `step_failed`
  # keeps those words.
  def handle_event("prepare_and_send", %{"form" => form, "step" => name}, socket)
      when is_map(form) and is_binary(name) do
    socket = assign(socket, inputs: inputs(socket.assigns.kind, form), unsent: false)

    with signer when is_binary(signer) <- signer(socket),
         {:ok, request} <- request(socket.assigns),
         {:ok, prepared} <- prepare(socket.assigns, request, signer) do
      socket = put_prepared(socket, signer, prepared)

      if name != "stock_approval" and prepared.blocked,
        do: {:reply, %{}, socket},
        else: {:reply, %{review: socket.assigns.review, send: name}, socket}
    else
      nil -> {:reply, %{}, sync(socket)}
      {:error, _reason} -> {:reply, %{}, socket |> sync() |> unsent()}
    end
  end

  def handle_event("step_sent", params, socket), do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event(
        "step_failed",
        %{"reason" => "step_unknown"},
        %{assigns: %{unsent: true}} = socket
      ),
      do: {:noreply, socket}

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

  def handle_async(:holdings, {:ok, {signer, {:ok, holdings}}}, socket) do
    if signer == signer(socket),
      do: {:noreply, assign(socket, holdings: holdings)},
      else: {:noreply, socket}
  end

  def handle_async(:holdings, _unread, socket), do: {:noreply, socket}

  def handle_async({:onchain_step, hash}, result, socket) do
    {:noreply,
     OnchainSteps.checked(socket, hash, result, fn socket, _entry ->
       send(self(), {:exposure_changed, socket.assigns.series.address})
       socket |> read_holdings() |> sync()
     end)}
  end

  # The steps follow the wallet that may act and the form as it stands.
  defp sync(socket) do
    socket = read_holdings(socket)

    case {signer(socket), request(socket.assigns)} do
      {signer, {:ok, request}} when is_binary(signer) ->
        %{inputs: inputs} = socket.assigns
        assigns = Map.take(socket.assigns, [:series, :kind, :current_human_id])

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

  # A panel with an amount shows what the wallet holds, read for the wallet that may act.
  defp read_holdings(%{assigns: %{kind: kind}} = socket) when kind in [:mint, :redeem] do
    case signer(socket) do
      nil ->
        assign(socket, holdings: nil)

      signer ->
        %{series: %{address: series}, current_human_id: human_id} = socket.assigns

        start_async(socket, :holdings, fn ->
          actor = %Human{human_account_id: human_id}
          {signer, Exposure.exposure_holdings(series, %{wallet: signer}, actor: actor)}
        end)
    end
  end

  defp read_holdings(socket), do: socket

  defp unsent(socket),
    do: assign(socket, unsent: true, press_note: OnchainSteps.unsent_note())

  defp put_prepared(socket, signer, prepared) do
    review =
      Review.new(socket.assigns.id, signer, prepared.chain, prepared.steps, socket.assigns.inputs)

    socket
    |> assign(prepared: prepared, refusal: nil)
    |> OnchainSteps.put_review(review)
  end

  defp prepare(assigns, request, signer) do
    actor = %Human{human_account_id: assigns.current_human_id}

    case Exposure.prepare_exposure(
           assigns.series.address,
           assigns.kind,
           Map.put(request, :signer, signer),
           actor: actor
         ) do
      {:ok, prepared} -> {:ok, prepared}
      {:error, error} -> {:error, Exposure.reason(error)}
    end
  end

  defp signer(socket), do: OnchainSteps.signer(socket.assigns.linked, socket.assigns.active)

  defp take_account(socket, account),
    do: OnchainSteps.take_account(socket, account, &sync/1)

  # The typed form, as the arguments of the action.
  defp request(%{kind: :mint, inputs: inputs, series: series}) do
    case F.parse_tokens(inputs["amount"] || "", series.stock.decimals) do
      nil -> {:error, :invalid_amount}
      amount -> {:ok, %{amount: amount}}
    end
  end

  defp request(%{kind: :redeem, inputs: inputs, series: %{status: :ended} = series}) do
    decimals = series.stock.decimals
    overnight = leg_amount(inputs["overnight"], decimals)
    session = leg_amount(inputs["session"], decimals)

    if is_integer(overnight) and is_integer(session) and overnight + session > 0,
      do: {:ok, %{overnight: overnight, session: session}},
      else: {:error, :invalid_amount}
  end

  defp request(%{kind: :redeem, inputs: inputs, series: series}) do
    case F.parse_tokens(inputs["pairs"] || "", series.stock.decimals) do
      nil -> {:error, :invalid_amount}
      pairs -> {:ok, %{overnight: pairs, session: pairs}}
    end
  end

  defp request(_assigns), do: {:ok, %{}}

  # After the end each leg may be left at zero.
  defp leg_amount(text, decimals) do
    if String.trim(text || "") in ["", "0"], do: 0, else: F.parse_tokens(text, decimals)
  end

  defp inputs(:mint, form), do: Map.take(form, ~w(amount))
  defp inputs(:redeem, form), do: Map.take(form, ~w(pairs overnight session))
  defp inputs(_kind, _form), do: %{}

  defp filled(%{kind: :mint, series: series}, holdings),
    do: %{"amount" => F.tokens(min(holdings.stock, room(series)), series.stock.decimals)}

  defp filled(%{kind: :redeem, series: series}, holdings),
    do: %{
      "pairs" => F.tokens(min(holdings.overnight, holdings.session), series.stock.decimals),
      "overnight" => F.tokens(holdings.overnight, series.stock.decimals),
      "session" => F.tokens(holdings.session, series.stock.decimals)
    }

  defp room(series), do: max(series.deposit_cap - series.accounted, 0)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        steps: steps(assigns),
        blocked: assigns.prepared && blocked_words(assigns.prepared.blocked, assigns),
        refused: refusal_words(assigns.refusal),
        decimals: assigns.series.stock.decimals
      )

    ~H"""
    <section id={@id} class="exposure-panel" phx-hook="OnchainSteps" data-onchain-prepare>
      <form
        :if={@kind in [:mint, :redeem]}
        id={"#{@id}-form"}
        class="exposure-panel__form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <.amount
          :if={@kind == :mint}
          name="amount"
          label="Amount"
          value={@inputs["amount"]}
          unit={@series.stock.symbol}
        />
        <.amount
          :if={@kind == :redeem and @series.status != :ended}
          name="pairs"
          label="Pairs"
          value={@inputs["pairs"]}
          unit="of each"
        />
        <.amount
          :if={@kind == :redeem and @series.status == :ended}
          name="overnight"
          label="After-hours"
          value={@inputs["overnight"]}
          unit={@series.overnight.symbol}
        />
        <.amount
          :if={@kind == :redeem and @series.status == :ended}
          name="session"
          label="Market-hours"
          value={@inputs["session"]}
          unit={@series.session.symbol}
        />
        <p :if={@holdings} class="exposure-panel__balance">
          <span>{balance(@kind, @holdings, @series)}</span>
          <button type="button" phx-click="max" phx-target={@myself}>Max</button>
        </p>
      </form>

      <dl :if={@prepared && @prepared.facts != %{}} class="exposure-panel__facts">
        <.facts kind={@kind} facts={@prepared.facts} series={@series} />
      </dl>

      <p :if={@refused} class="exposure-panel__problem" role="alert">{@refused}</p>
      <p class="exposure-panel__note" hidden={!@mismatch}>{@mismatch}</p>

      <ol class="exposure-panel__steps">
        <li :for={step <- @steps} class="exposure-panel__step" data-state={step.state}>
          <P.button
            variant={if step.approval?, do: "secondary", else: nil}
            data-onchain-step={step.name}
            disabled={!step.approval? and @blocked != nil}
            aria-describedby={(!step.approval? and @blocked) && "#{@id}-#{step.name}-why"}
          >
            <span data-press-label>{step.label}</span>
          </P.button>
          <div class="exposure-panel__step-words">
            <span :if={step.words}>{step.words}</span>
            <span :if={!step.approval? and @blocked} id={"#{@id}-#{step.name}-why"}>{@blocked}</span>
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

      <p :if={@press_note} class="exposure-panel__note" role="status">{@press_note}</p>
      <p class="exposure-panel__note" role="status" data-onchain-lost hidden>
        Connection lost, so nothing was sent. Press again once it's back.
      </p>
    </section>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :unit, :string, required: true

  defp amount(assigns) do
    ~H"""
    <label class="exposure-panel__field">
      <span>{@label}</span>
      <span class="exposure-panel__input">
        <input
          name={@name}
          value={@value}
          inputmode="decimal"
          autocomplete="off"
          spellcheck="false"
          placeholder="0"
          data-onchain-input={@name}
        />
        <span aria-hidden="true">{@unit}</span>
      </span>
    </label>
    """
  end

  defp balance(:mint, holdings, series),
    do: "Wallet: #{F.tokens(holdings.stock, series.stock.decimals)} #{series.stock.symbol}"

  defp balance(:redeem, holdings, series),
    do:
      "Wallet: #{F.tokens(holdings.overnight, series.stock.decimals)} After-hours, #{F.tokens(holdings.session, series.stock.decimals)} Market-hours"

  attr :kind, :atom, required: true
  attr :facts, :map, required: true
  attr :series, :map, required: true

  defp facts(%{kind: :mint} = assigns) do
    ~H"""
    <dt>You deposit</dt>
    <dd>{F.tokens(@facts.amount, @series.stock.decimals)} {@series.stock.symbol}</dd>
    <dt>You receive</dt>
    <dd>
      {F.tokens(@facts.amount, @series.stock.decimals)} {@series.overnight.symbol} and {F.tokens(
        @facts.amount,
        @series.stock.decimals
      )} {@series.session.symbol}
    </dd>
    """
  end

  defp facts(%{kind: :redeem} = assigns) do
    ~H"""
    <dt>You receive</dt>
    <dd>
      {if @facts.paid, do: F.tokens(@facts.paid, @series.stock.decimals), else: "—"} {@series.stock.symbol}
    </dd>
    """
  end

  defp facts(%{kind: :update, facts: %{source: %{round: round}}} = assigns) do
    assigns = assign(assigns, round: round)

    ~H"""
    <dt>Price</dt>
    <dd>{kind_word(@facts.kind)} {F.moment(@facts.at)} New York</dd>
    <dt>Feed round</dt>
    <dd>{@round}</dd>
    """
  end

  defp facts(%{kind: :update} = assigns) do
    ~H"""
    <dt>Price</dt>
    <dd>{kind_word(@facts.kind)} {F.moment(@facts.at)} New York</dd>
    """
  end

  defp facts(%{kind: :end} = assigns) do
    ~H"""
    <dt>Missing price</dt>
    <dd>{F.moment(@facts.at)} New York</dd>
    """
  end

  defp kind_word(:open), do: "Open,"
  defp kind_word(:close), do: "Close,"

  # The steps shown before any review exists name the same buttons, so a
  # first press still has something to press.
  defp steps(%{kind: kind, review: review, presses: presses, prepared: prepared} = assigns) do
    kind
    |> step_names(prepared)
    |> Enum.map(fn name ->
      entry = review && OnchainSteps.entry(presses, review, name)
      described = entry && OnchainSteps.describe(entry, "Base")
      approval? = name == "stock_approval"

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

  defp step_names(:mint, _prepared), do: ~w(stock_approval mint)
  defp step_names(:redeem, _prepared), do: ~w(redeem)
  defp step_names(:end, _prepared), do: ~w(end)
  defp step_names(:update, %{steps: steps}) when steps != [], do: Enum.map(steps, & &1.step)
  defp step_names(:update, _prepared), do: ~w(record settle)

  defp label("stock_approval", %{series: series}), do: "Approve #{series.stock.symbol}"
  defp label("mint", _assigns), do: "Mint"
  defp label("redeem", _assigns), do: "Return"
  defp label("record", _assigns), do: "Record price"
  defp label("settle", _assigns), do: "Apply price"
  defp label("end", _assigns), do: "End series"

  defp blocked_words(nil, _assigns), do: nil
  defp blocked_words(:approve_first, _assigns), do: "Approve first"
  defp blocked_words(:not_open, _assigns), do: "Opens once the first close is applied"
  defp blocked_words(:ended, _assigns), do: "This series has ended"

  defp blocked_words(:above_cap, %{series: series}),
    do:
      "Only #{F.tokens(room(series), series.stock.decimals)} #{series.stock.symbol} left under the cap"

  defp blocked_words(:backing_short, _assigns),
    do: "The series holds less stock than it owes, so this can't go through now"

  defp blocked_words(:not_enough_stock, %{series: series}),
    do: "Not enough #{series.stock.symbol} in this wallet"

  defp blocked_words(:pair_required, _assigns),
    do: "Until the series ends, return equal amounts of each"

  defp blocked_words(:more_than_held, _assigns), do: "More than this wallet holds"

  defp blocked_words(:too_early, %{prepared: %{facts: %{recordable_at: at}}}),
    do: "Can be recorded from #{F.moment(at)} New York"

  defp blocked_words(:price_too_old, _assigns),
    do: "The feed had no price in the 84 hours before this moment"

  defp blocked_words(:missed_deadline, _assigns),
    do: "Too late to record this price; the series can be ended"

  defp blocked_words(:price_available, _assigns), do: "This price can still be applied"

  defp blocked_words(:not_overdue, %{series: %{next: next}}),
    do: "Possible after #{F.moment(next.deadline)} New York"

  defp refusal_words(nil), do: nil
  defp refusal_words(:invalid_amount), do: nil
  defp refusal_words(:wrong_signer), do: nil
  defp refusal_words(:unknown_series), do: "This series isn't on this site."
  defp refusal_words(_unavailable), do: "Base couldn't be read just now. Try again in a moment."
end
