defmodule AutolaunchWeb.ExposureComponent do
  @moduledoc """
  The wallet panel for one Exposure action on one week: buy one token (`leg`)
  with USDC or sell it for USDC through its Aerodrome pool, deposit the stock
  for a pair, redeem tokens for the stock, or update prices. The server builds
  every step (`Autolaunch.Exposure.prepare_exposure/4`, the same action agents
  call) for the wallet that may act (`AutolaunchWeb.OnchainSteps`), and every
  press goes straight to the wallet.

  An approval is its own step and stays pressable once done. The action is
  disabled only when the chain, read at the latest block for this panel, makes
  it certain to fail, with the reason beside it; Update prices never is. A
  press made before a new amount reached the server asks for the matching
  steps first.

  The page passes `kind`, the week's reading as `series`, and the panel's
  `session_lease` and `current_human_id`. A landed step tells the page with
  `{:exposure_changed, week}`.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Exposure
  alias Autolaunch.Exposure.Chain
  alias AutolaunchWeb.ExposureFormat, as: F
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.OnchainSteps
  alias Regent.Primitives, as: P
  alias RegentChain.Review

  @stale_ms 10 * 60_000
  @approvals ~w(stock_approval usdc_approval token_approval)
  @usdc_decimals 6

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
       unsent: false,
       holdings: nil,
       refresh: nil,
       leg: nil
     )}
  end

  @impl true
  def update(%{refresh: ref}, %{assigns: %{refresh: ref}} = socket), do: {:ok, sync(socket)}
  def update(%{refresh: _older}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, socket |> OnchainSteps.adopt() |> sync()}
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket),
    do: {:noreply, socket |> assign(active: OnchainSteps.active_wallet(params)) |> sync()}

  def handle_event("change", params, socket),
    do: {:noreply, socket |> assign(inputs: inputs(socket.assigns.kind, params)) |> sync()}

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

      if name not in @approvals and prepared.blocked,
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
          {:noreply, socket |> put_prepared(signer, prepared) |> refresh_later()}

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
     OnchainSteps.checked(socket, hash, result, fn socket, entry ->
       send(self(), {:exposure_changed, socket.assigns.series.week})
       done(socket, entry.step.step)
       socket |> read_holdings() |> sync()
     end)}
  end

  # A trade, a deposit or a redemption that landed tells the page what it
  # moved, for its toast.
  defp done(%{assigns: %{prepared: %{facts: facts}, series: series}}, step)
       when step in ["buy", "sell", "deposit", "redeem"],
       do: send(self(), {:exposure_done, %{kind: step, lines: done_lines(step, facts, series)}})

  defp done(_socket, _step), do: :ok

  defp done_lines("deposit", %{amount: amount}, series) do
    tokens = F.tokens(amount, series.stock.decimals)
    ["You received #{tokens} #{series.overnight.symbol} and #{tokens} #{series.session.symbol}."]
  end

  defp done_lines("redeem", %{paid: paid}, series) when is_integer(paid),
    do: ["You received #{F.tokens(paid, series.stock.decimals)} #{series.stock.symbol}."]

  defp done_lines("redeem", _facts, _series), do: []

  defp done_lines("buy", %{amount: amount, leg: leg}, series),
    do: [
      "You paid #{F.usdc(amount)} for #{Map.fetch!(series, leg).symbol}. What you received is in your wallet and portfolio."
    ]

  defp done_lines("sell", %{amount: amount, leg: leg}, series),
    do: [
      "You sold #{F.tokens(amount, series.stock.decimals)} #{Map.fetch!(series, leg).symbol} for USDC."
    ]

  @doc "The note a landed trade, deposit or redemption leaves on the page, with View portfolio."
  attr :id, :string, required: true
  attr :done, :map, required: true
  attr :dismiss, :string, required: true

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

  defp done_title("buy"), do: "Bought"
  defp done_title("sell"), do: "Sold"
  defp done_title("deposit"), do: "Deposited"
  defp done_title("redeem"), do: "Redeemed"

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
  defp read_holdings(%{assigns: %{kind: kind}} = socket)
       when kind in [:buy, :sell, :deposit, :redeem] do
    case signer(socket) do
      nil ->
        assign(socket, holdings: nil)

      signer ->
        %{series: %{week: week}, current_human_id: human_id} = socket.assigns

        start_async(socket, :holdings, fn ->
          actor = %Human{human_account_id: human_id}
          {signer, Exposure.exposure_holdings(week, %{wallet: signer}, actor: actor)}
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

  # A swap's deadline is twenty minutes after its review, so the steps are
  # built again once they are ten minutes old. The page reads the week again
  # whenever a price falls due, which builds them again too. Only the newest
  # timer counts, so the page's own re-reads never stack them up.
  defp refresh_later(socket) do
    ref = make_ref()
    Phoenix.LiveView.send_update_after(self(), socket.assigns.myself, %{refresh: ref}, @stale_ms)
    assign(socket, refresh: ref)
  end

  defp prepare(assigns, request, signer) do
    actor = %Human{human_account_id: assigns.current_human_id}

    case Exposure.prepare_exposure(
           assigns.series.week,
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

  # The typed form, as the arguments of the action. A comma is never read as a
  # decimal point or a thousands mark, since "0,4" means 0.4 to many people and
  # 4 to others.
  defp request(%{inputs: inputs} = assigns) do
    if Enum.any?(Map.values(inputs), &String.contains?(&1, ",")),
      do: {:error, :comma_amount},
      else: typed(assigns)
  end

  defp typed(%{kind: :buy, inputs: inputs, leg: leg}) do
    case F.parse_tokens(inputs["amount"] || "", @usdc_decimals) do
      nil -> {:error, :invalid_amount}
      amount -> {:ok, %{amount: amount, leg: leg}}
    end
  end

  defp typed(%{kind: :sell, inputs: inputs, leg: leg, series: series}) do
    case F.parse_tokens(inputs["amount"] || "", series.stock.decimals) do
      nil -> {:error, :invalid_amount}
      amount -> {:ok, %{amount: amount, leg: leg}}
    end
  end

  defp typed(%{kind: :deposit, inputs: inputs, series: series}) do
    case F.parse_tokens(inputs["amount"] || "", series.stock.decimals) do
      nil -> {:error, :invalid_amount}
      amount -> {:ok, %{amount: amount}}
    end
  end

  defp typed(%{kind: :redeem, inputs: inputs, series: %{status: :ended} = series}) do
    decimals = series.stock.decimals
    overnight = leg_amount(inputs["overnight"], decimals)
    session = leg_amount(inputs["session"], decimals)

    if is_integer(overnight) and is_integer(session) and overnight + session > 0,
      do: {:ok, %{overnight: overnight, session: session}},
      else: {:error, :invalid_amount}
  end

  defp typed(%{kind: :redeem, inputs: inputs, series: series}) do
    case F.parse_tokens(inputs["pairs"] || "", series.stock.decimals) do
      nil -> {:error, :invalid_amount}
      pairs -> {:ok, %{overnight: pairs, session: pairs}}
    end
  end

  defp typed(_assigns), do: {:ok, %{}}

  # After the end each leg may be left at zero.
  defp leg_amount(text, decimals) do
    if String.trim(text || "") in ["", "0"], do: 0, else: F.parse_tokens(text, decimals)
  end

  defp inputs(kind, form) when kind in [:buy, :sell, :deposit], do: Map.take(form, ~w(amount))
  defp inputs(:redeem, form), do: Map.take(form, ~w(pairs overnight session))
  defp inputs(_kind, _form), do: %{}

  defp filled(%{kind: :buy}, holdings),
    do: %{"amount" => F.tokens(holdings.usdc, @usdc_decimals)}

  defp filled(%{kind: :sell, leg: leg, series: series}, holdings),
    do: %{"amount" => F.tokens(Map.fetch!(holdings, leg), series.stock.decimals)}

  defp filled(%{kind: :deposit, series: series}, holdings),
    do: %{"amount" => F.tokens(min(holdings.stock, Chain.room(series)), series.stock.decimals)}

  defp filled(%{kind: :redeem, series: series}, holdings),
    do: %{
      "pairs" => F.tokens(min(holdings.overnight, holdings.session), series.stock.decimals),
      "overnight" => F.tokens(holdings.overnight, series.stock.decimals),
      "session" => F.tokens(holdings.session, series.stock.decimals)
    }

  # Max fills the boxes in the browser at the press, with the wallet as last
  # read, so a press straight after it carries the amounts however long the
  # server takes; each box's input event runs the form's change.
  defp max_fill(id, kind, leg, series, holdings) do
    %{kind: kind, leg: leg, series: series}
    |> filled(holdings)
    |> Enum.reduce(%JS{}, fn {name, value}, js ->
      JS.dispatch(js, "autolaunch:fill",
        to: "##{id}-form input[name=#{name}]",
        detail: %{value: value}
      )
    end)
  end

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
        :if={@kind in [:buy, :sell, :deposit, :redeem]}
        id={"#{@id}-form"}
        class="exposure-panel__form"
        phx-change="change"
        phx-submit="change"
        phx-target={@myself}
      >
        <.amount
          :if={@kind == :buy}
          name="amount"
          label="Spend"
          value={@inputs["amount"]}
          unit="USDC"
        />
        <.amount
          :if={@kind == :sell}
          name="amount"
          label="Sell"
          value={@inputs["amount"]}
          unit={Map.fetch!(@series, @leg).symbol}
        />
        <.amount
          :if={@kind == :deposit}
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
          <span>{balance(@kind, @holdings, @series, @leg)}</span>
          <button type="button" phx-click={max_fill(@id, @kind, @leg, @series, @holdings)}>
            Max
          </button>
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

  defp balance(:buy, holdings, _series, _leg),
    do: "Wallet: #{F.tokens(holdings.usdc, @usdc_decimals)} USDC"

  defp balance(:sell, holdings, series, leg),
    do:
      "Wallet: #{F.tokens(Map.fetch!(holdings, leg), series.stock.decimals)} #{Map.fetch!(series, leg).symbol}"

  defp balance(:deposit, holdings, series, _leg),
    do: "Wallet: #{F.tokens(holdings.stock, series.stock.decimals)} #{series.stock.symbol}"

  defp balance(:redeem, holdings, series, _leg),
    do:
      "Wallet: #{F.tokens(holdings.overnight, series.stock.decimals)} After-hours, #{F.tokens(holdings.session, series.stock.decimals)} Market-hours"

  attr :kind, :atom, required: true
  attr :facts, :map, required: true
  attr :series, :map, required: true

  defp facts(%{kind: :buy} = assigns) do
    ~H"""
    <dt>You pay</dt>
    <dd>{F.tokens(@facts.amount, @facts.usdc_decimals)} USDC</dd>
    <dt>You receive</dt>
    <dd>
      about {expected(@facts.expected, @series.stock.decimals)} {Map.fetch!(@series, @facts.leg).symbol},
      at least {expected(@facts.minimum, @series.stock.decimals)}
    </dd>
    """
  end

  defp facts(%{kind: :sell} = assigns) do
    ~H"""
    <dt>You sell</dt>
    <dd>
      {F.tokens(@facts.amount, @series.stock.decimals)} {Map.fetch!(@series, @facts.leg).symbol}
    </dd>
    <dt>You receive</dt>
    <dd>
      about {expected(@facts.expected, @facts.usdc_decimals)} USDC, at least {expected(
        @facts.minimum,
        @facts.usdc_decimals
      )}
    </dd>
    """
  end

  defp facts(%{kind: :deposit} = assigns) do
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

  defp facts(%{kind: :settle} = assigns) do
    ~H"""
    <dt>Due</dt>
    <dd id="exposure-due">{due_words(@facts)}</dd>
    <dt :if={@facts.next}>Next</dt>
    <dd :if={@facts.next}>
      {if @facts.next.kind == :open, do: "Open", else: "Close"}, {F.moment(@facts.next.at)}, applies from {F.time(
        @facts.next.applies_at
      )} New York
    </dd>
    """
  end

  # How many prices Update prices would write now, and whether one of them
  # ends the week.
  defp due_words(%{due: 0, ends: true}), do: "Ends the week"
  defp due_words(%{due: 0}), do: "Nothing yet"
  defp due_words(%{due: 1, ends: true}), do: "1 price, which ends the week"
  defp due_words(%{due: 1}), do: "1 price"
  defp due_words(%{due: due, ends: true}), do: "#{due} prices, the last of which ends the week"
  defp due_words(%{due: due}), do: "#{due} prices"

  defp expected(nil, _decimals), do: "—"
  defp expected(amount, decimals), do: F.tokens(amount, decimals)

  # The steps shown before any review exists name the same buttons, so a
  # first press still has something to press.
  defp steps(%{kind: kind, review: review, presses: presses, prepared: prepared} = assigns) do
    kind
    |> step_names(prepared)
    |> Enum.map(fn name ->
      entry = review && OnchainSteps.entry(presses, review, name)
      described = entry && OnchainSteps.describe(entry, "Base")
      approval? = name in @approvals

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

  defp step_names(:buy, _prepared), do: ~w(usdc_approval buy)
  defp step_names(:sell, _prepared), do: ~w(token_approval sell)
  defp step_names(:deposit, _prepared), do: ~w(stock_approval deposit)
  defp step_names(:redeem, _prepared), do: ~w(redeem)
  defp step_names(:settle, _prepared), do: ~w(settle)

  defp label("usdc_approval", _assigns), do: "Approve USDC"

  defp label("token_approval", %{series: series, leg: leg}),
    do: "Approve #{Map.fetch!(series, leg).symbol}"

  defp label("buy", _assigns), do: "Buy"
  defp label("sell", _assigns), do: "Sell"
  defp label("stock_approval", %{series: series}), do: "Approve #{series.stock.symbol}"
  defp label("deposit", %{series: series}), do: "Deposit #{series.stock.symbol}"
  defp label("redeem", _assigns), do: "Redeem"
  defp label("settle", _assigns), do: "Update prices"

  defp blocked_words(nil, _assigns), do: nil
  defp blocked_words(:approve_first, _assigns), do: "Approve first"
  defp blocked_words(:no_liquidity, _assigns), do: "Trading opens when liquidity is added"
  defp blocked_words(:too_small, _assigns), do: "Too small for the pool to pay anything back"
  defp blocked_words(:not_enough_usdc, _assigns), do: "Not enough USDC in this wallet"

  defp blocked_words(:deposits_closed, _assigns),
    do: "Deposits have closed; next week opens an hour after the close"

  defp blocked_words(:paused, _assigns), do: "Opening new weeks is paused"
  defp blocked_words(:not_open, _assigns), do: "Opens once the first price applies"
  defp blocked_words(:ended, _assigns), do: "This week has ended"

  defp blocked_words(:above_cap, %{series: series}),
    do:
      "Only #{F.tokens(Chain.room(series), series.stock.decimals)} #{series.stock.symbol} left under the cap"

  defp blocked_words(:backing_short, _assigns),
    do: "The series holds less stock than it owes, so this can't go through now"

  defp blocked_words(:not_enough_stock, %{series: series}),
    do: "Not enough #{series.stock.symbol} in this wallet"

  defp blocked_words(:pair_required, _assigns),
    do: "Until the week ends, redeem equal amounts of each"

  defp blocked_words(:more_than_held, _assigns), do: "More than this wallet holds"

  defp refusal_words(nil), do: nil
  defp refusal_words(:invalid_amount), do: nil
  defp refusal_words(:comma_amount), do: "Write amounts with a point, as in 0.4."
  defp refusal_words(:wrong_signer), do: nil
  defp refusal_words(:unknown_week), do: "This week isn't on this site."
  defp refusal_words(:week_not_open), do: "This week opens with its first deposit."
  defp refusal_words(_unavailable), do: "Base couldn't be read just now. Try again in a moment."
end
