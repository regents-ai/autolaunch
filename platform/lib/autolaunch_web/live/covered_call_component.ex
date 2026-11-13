defmodule AutolaunchWeb.CoveredCallComponent do
  @moduledoc """
  The wallet panel for one covered-call action: list calls, buy them, exercise,
  stop selling, collect stock or collect USDC, and for bids place one, sell
  into one, raise, stop or refund one, the way the token page's Stake and
  Claim and the Buy window work. Its button opens a review over the panel
  with the steps the wallet sends, one button at a time, and the review closes
  when the chain confirms the last one. The page then shows what moved (`toast/1`), from
  `{:covered_call_done, done}`: an action can take its own panel off the page
  (the last calls bought, a row's last collection).

  The server builds every step (`Autolaunch.CoveredCalls.prepare_covered_call_steps/3`,
  the same action agents call) for the wallet that may act
  (`AutolaunchWeb.OnchainSteps`), and every press of the wallet button goes
  straight to the wallet. An approval is its own step; one the chain already
  holds shows as done. The button is disabled only when the chain, read at the
  latest block for the action as it stands, makes it certain to fail, with the
  reason beside it.

  The page passes `kind`, `symbol`, `unit` (raw units per whole token), the
  `listing` or `bid` an action is on, the panel's `session_lease` and
  `current_human_id`, and, for a row of actions such as the portfolio's,
  `variant="secondary"` for its button. Listing, buying, bidding and selling
  into a bid take the page's ticket as `order`, the action's arguments (`nil`
  until every figure of it reads); an exercise and a raise have their own
  amount field, an exercise starting at `holding`. A landed step tells the
  page with `{:covered_calls_changed, symbol, press}`, `press` naming the
  listing and its seller, the bid and its bidder (`nil` where the action has
  none) and the wallet that sent it.

  A ticket's panel also tells the page what the signed-in account's wallet has
  on the market, with `{:covered_call_wallet, symbol, wallet}` (`nil` signed
  out or unread): its `balance` of the stock, for the Sell tickets' Max, and
  `exercise_by`, when the exercise window closes on calls it holds whose
  window is open or opens within three days (`nil` for none). It is the wallet
  the panel shows figures for, read at the latest block when it changes, when
  the page comes back into view and when a step lands.

  `stock/1` names the stock a ticket is on, and every review starts with it.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.CoveredCalls
  alias Autolaunch.CoveredCalls.{Book, Deployment, Terms}
  alias AutolaunchWeb.CoveredCallsFormat, as: F
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.{OnchainSteps, StakeComponent}
  alias Phoenix.LiveView.JS
  alias Regent.Primitives, as: P
  alias RegentChain.{Presses, Review}

  # The actions whose figures are the page's ticket, and those with an amount
  # typed in their own panel.
  @tickets [:list, :fill, :bid, :sell_to_bid]
  @typed [:exercise, :raise_bid]
  # How long before its window opens a holder is told when it closes.
  @soon 3 * 86_400

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
       bid: nil,
       holding: nil,
       order: nil,
       variant: "primary",
       balance_for: nil,
       balance_reads: 0
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Until the person types, an exercise follows the holding as the page reads
    # it. The page's tickets follow its fields (`order`).
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
  def handle_event("refresh_funds", _params, socket),
    do: {:noreply, socket |> update(:balance_reads, &(&1 + 1)) |> sync()}

  def handle_event("change", params, socket) do
    socket = assign(socket, inputs: Map.take(params, ["amount"]), typed: true, notice: nil)
    {:noreply, sync(socket)}
  end

  # The exercise and raise forms send their amount with the press, so a figure
  # typed a moment ago is the one reviewed. The page's ticket reaches the panel
  # before a press after it: the page hears its form's change first.
  def handle_event("review", params, socket) do
    socket =
      if typed?(socket.assigns.kind) and is_map_key(params, "amount"),
        do: assign(socket, inputs: Map.take(params, ["amount"]), typed: true),
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

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2, &step_reverted/2)}

  def handle_async(:balance, {:ok, {key, balance}}, socket) do
    if key == socket.assigns.balance_for,
      do: send(self(), {:covered_call_wallet, socket.assigns.symbol, balance})

    {:noreply, socket}
  end

  def handle_async(:balance, {:exit, _reason}, socket), do: {:noreply, socket}

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
        assigns = Map.take(socket.assigns, [:symbol, :kind, :current_human_id])

        socket
        |> assign(refusal: nil)
        |> start_async(:quote, fn -> {request, signer, prepare(assigns, request, signer)} end)

      {_signer, request} ->
        refusal = if match?({:error, _}, request), do: elem(request, 1)
        assign(socket, quote: nil, refusal: refusal)
    end
    |> assign(mismatch: OnchainSteps.mismatch_note(socket.assigns.linked, socket.assigns.active))
    |> read_balance()
  end

  # What the wallet has on the market, for the page's Max and its notice of a
  # window about to close: the wallet the panel shows figures for while signed
  # in, read again for each new wallet and each ask (`balance_reads`).
  defp read_balance(%{assigns: %{kind: kind} = assigns} = socket) when kind in @tickets do
    wallet =
      if is_list(assigns.linked),
        do: OnchainSteps.shown_wallet(assigns.linked, assigns.signed_in, assigns.active)

    key = {wallet, assigns.balance_reads}
    %{symbol: symbol, current_human_id: id} = assigns

    if key == assigns.balance_for,
      do: socket,
      else:
        socket
        |> assign(balance_for: key)
        |> start_async(:balance, fn -> {key, balance(symbol, id, wallet)} end)
  end

  defp read_balance(socket), do: socket

  defp balance(_symbol, _id, nil), do: nil

  defp balance(symbol, id, wallet) do
    case CoveredCalls.read_covered_call_positions(symbol, %{wallet: wallet},
           actor: %Human{human_account_id: id}
         ) do
      {:ok, positions} -> %{balance: positions.balance, exercise_by: exercise_by(positions)}
      {:error, _error} -> nil
    end
  end

  # When the window closes on calls the wallet holds, for the soonest window
  # that is open or opens within three days.
  defp exercise_by(%{holdings: holdings, now: now}) do
    for(
      %{listing: %{expiry: expiry}, held: held} <- holdings,
      held > 0,
      closes = expiry + Terms.exercise_window(),
      now < closes and expiry - now <= @soon,
      do: closes
    )
    |> Enum.min(fn -> nil end)
  end

  # The form's button: the steps for the form as it stands, read again now.
  # When the chain makes the action certain to fail, it says why and nothing
  # opens; an approval still to send is a step of the review.
  defp reviewed(socket) do
    case {signer(socket), request(socket.assigns)} do
      {nil, _request} ->
        assign(socket, notice: no_signer(socket.assigns))

      {_signer, {:error, :invalid_amount}} ->
        assign(socket, notice: unreadable(socket.assigns.kind))

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
            |> assign(notice: nil, press_note: nil, quote: {request, signer, prepared})
            |> OnchainSteps.put_review(review)

          {:ok, prepared} ->
            socket
            |> assign(quote: {request, signer, prepared})
            |> assign(notice: blocked_words(prepared.blocked, socket.assigns) <> ".")

          {:error, reason} ->
            assign(socket, notice: refusal_words(reason) || unreadable(socket.assigns.kind))
        end
    end
  end

  # A ticket whose figures don't read: what each figure takes.
  defp unreadable(kind) when kind in [:list, :bid],
    do: "Enter an amount above zero and prices to the cent, with a dot for decimals (1.50)."

  defp unreadable(_kind), do: "Enter an amount above zero, with a dot for decimals (1.5)."

  defp no_signer(%{linked: nil}), do: "Sign in to use your wallet here."

  defp no_signer(%{linked: linked, active: active}),
    do: OnchainSteps.failure_note("wallet_unavailable", linked, active, "Base")

  # A step landed: the page reads the market again. When every step of the
  # open review has landed once, whichever press of it landed, the review
  # closes and the page says what moved.
  defp confirmed(socket, %{review: %{id: id, signer: signer}, name: name}) do
    Book.expire(socket.assigns.symbol)
    socket = update(socket, :balance_reads, &(&1 + 1))

    send(
      self(),
      {:covered_calls_changed, socket.assigns.symbol,
       %{
         listing_id: socket.assigns.listing[:id],
         seller: socket.assigns.listing[:seller],
         bid_id: socket.assigns.bid[:id],
         bidder: socket.assigns.bid[:bidder],
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

  # A step of the open review that did not go through: the action is reviewed
  # again at once from the chain as it is now (`OnchainSteps.rebuild_reverted/4`).
  defp step_reverted(socket, entry) do
    note = reverted_copy(socket.assigns.kind)

    OnchainSteps.rebuild_reverted(socket, entry, note, fn socket ->
      socket |> closed() |> reviewed() |> OnchainSteps.rebuilt(note)
    end)
  end

  defp finished(socket) do
    %{kind: kind, reviewed: prepared} = socket.assigns

    send(
      self(),
      {:covered_call_done, %{kind: kind, lines: done_lines(kind, prepared.facts, socket.assigns)}}
    )

    socket
    |> assign(cleared(kind, socket.assigns))
    |> closed()
  end

  defp closed(socket) do
    socket
    |> assign(reviewed: nil, landed: MapSet.new(), press_note: nil)
    |> OnchainSteps.put_review(nil)
  end

  defp prepare(assigns, request, signer) do
    actor = %Human{human_account_id: assigns.current_human_id}

    case CoveredCalls.prepare_covered_call_steps(
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

  # The action's arguments: the page's ticket, the typed amount on the listing
  # or bid, or the listing or bid alone.
  defp request(%{kind: kind, order: nil}) when kind in @tickets, do: {:error, :invalid_amount}
  defp request(%{kind: kind, order: order}) when kind in @tickets, do: {:ok, order}

  defp request(%{kind: kind, inputs: inputs, unit: unit} = assigns) when kind in @typed do
    case F.parse_tokens(inputs["amount"], unit) do
      nil -> {:error, :invalid_amount}
      amount -> {:ok, Map.put(subject(assigns), :amount, amount)}
    end
  end

  defp request(assigns), do: {:ok, subject(assigns)}

  defp subject(%{bid: nil, listing: listing}), do: %{listing_id: listing.id}
  defp subject(%{bid: bid}), do: %{bid_id: bid.id}

  defp typed?(kind), do: kind in @typed

  # A ticket keeps a line for the reason under its button, so the receipt under
  # it on a phone never moves when a reason comes or goes.
  defp ticket?(kind), do: kind in @tickets

  defp defaults(%{kind: :exercise, listing: listing, unit: unit, holding: held}),
    do: %{"amount" => F.tokens(held || listing.filled, unit)}

  defp defaults(_assigns), do: %{}

  # The page clears its own tickets (`{:covered_call_done, done}`); an exercise
  # follows the holding again as the page reads it next (`update/2`), and a
  # raise starts empty.
  defp cleared(kind, _assigns) when kind in @tickets, do: []
  defp cleared(_kind, assigns), do: [inputs: defaults(assigns), typed: false]

  defp approval?(name), do: name in ~w(stock_approval usdc_approval)

  # The figures for the action as it stands and the wallet that may act, once
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
            :if={typed?(@kind)}
            id={"#{@id}-form"}
            class="covered-call-panel__form"
            phx-change="change"
            phx-submit="review"
            phx-target={@myself}
          >
            <.field
              id={"#{@id}-amount"}
              name="amount"
              label="Amount"
              value={@inputs["amount"]}
              unit={@symbol}
            />
            <.action {action_assigns(assigns)} type="submit" />
          </form>
          <.action :if={!typed?(@kind)} {action_assigns(assigns)} type="button" />
        </div>

        <StakeComponent.stake_review
          id={"#{@id}-review-panel"}
          open={!!@review}
          title={@reviewed && title(@kind)}
          facts={
            (@reviewed &&
               [
                 ["Stock", review_stock(%{id: "#{@id}-review-stock", stock: @reviewed.market})]
                 | facts(@kind, @reviewed.facts, assigns)
               ]) || []
          }
          steps={@steps}
          next_step={@next_step}
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

  # What the action comes to (the page's receipt says it for a ticket, and a
  # bid's row its figures), and the button that reviews it: a submit inside an
  # amount form, so the press carries the amount as typed, or a plain button.
  # Neither sends anything to the wallet.
  defp action(assigns) do
    ~H"""
    <dl
      :if={@prepared && @kind in [:exercise, :claim, :collect_strike, :cancel]}
      class="covered-call-panel__facts"
    >
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
    <p :if={@blocked || ticket?(@kind)} id={"#{@id}-why"} class="covered-call-panel__reason">
      {@blocked}
    </p>
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

  attr :done, :map,
    required: true,
    doc: "`%{kind: kind, lines: [String.t()]}` from `{:covered_call_done, done}`"

  attr :dismiss, :string, required: true, doc: "the event the dismiss button sends"
  attr :target, :any, default: nil
  attr :portfolio, :boolean, default: true, doc: "false on the portfolio itself"

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
        <AutolaunchWeb.Components.PortfolioLink.portfolio_link :if={@portfolio} />
      </div>
      <P.button
        type="button"
        variant="quiet"
        phx-click={@dismiss}
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <Regent.Icons.icon name="x" class="dismiss-icon" />
      </P.button>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :at, :integer, required: true

  @doc """
  A time in the reader's own time zone once the page is live (`LocalTime`),
  with the time in UTC, the time the contract keeps, beside it.
  """
  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      class="covered-calls__local"
      datetime={@at |> DateTime.from_unix!() |> DateTime.to_iso8601()}
      phx-hook="LocalTime"
      phx-mounted={JS.ignore_attributes(["data-local"])}
    >{F.expiry(@at)}</time><small class="covered-calls__utc">{F.utc_time(@at)}</small>
    """
  end

  attr :id, :string, required: true
  attr :market, :map, required: true, doc: "a market of `Autolaunch.CoveredCalls.Deployment`"

  @doc """
  The stock a ticket is on, under its title: its symbol, who issues it, its
  chain and its exact address.
  """
  def stock(assigns) do
    assigns = assign(assigns, stock: Deployment.identity(assigns.market))

    ~H"""
    <p class="covered-calls__stock">
      {@stock.symbol} · {@stock.issuer} tokenized stock · {@stock.chain} ·
      <P.address id={@id} address={@stock.stock} />
    </p>
    """
  end

  # The same in a review's first line, before anything is signed.
  defp review_stock(assigns) do
    ~H"""
    {@stock.symbol}, {@stock.issuer}, {@stock.chain}, <P.address id={@id} address={@stock.stock} />
    """
  end

  # What the action comes to, as label and value, in the form and its review.
  defp facts(:list, facts, %{unit: unit, symbol: symbol}) do
    premium = F.total(facts.amount, facts.premium_per_token, unit)
    fee = Terms.fee(premium)

    [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Strike", "#{F.usd(facts.strike_per_token)} per #{symbol}"],
      ["Opens", F.expiry(facts.expiry)],
      ["Closes", F.window_closes(facts.expiry)],
      ["Premium", "#{F.usd(premium)} if all sell"],
      ["Fee", F.usd(fee)],
      ["You receive", "#{F.usd(premium - fee)} if all sell, paid as each buyer buys"],
      ["If exercised", F.usd(F.total(facts.amount, facts.strike_per_token, unit))],
      locked(facts.expiry)
    ]
  end

  defp facts(:fill, facts, %{unit: unit, symbol: symbol, listing: listing}),
    do: [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["You pay", F.usd_due(facts.premium)],
      ["Fee", "None on top"],
      ["To exercise", F.usd_due(facts.strike)],
      break_even(listing.strike_per_token + listing.premium_per_token, symbol),
      ["Opens", F.expiry(facts.expiry)],
      ["Closes", F.window_closes(facts.expiry)]
    ]

  defp facts(:exercise, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["You pay", F.usd_due(facts.strike)],
      ["To collect", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Window closes", F.window_closes(facts.expiry)]
    ]

  defp facts(:bid, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Strike", "#{F.usd(facts.strike_per_token)} per #{symbol}"],
      ["Premium", "#{F.usd(facts.premium_per_token)} per #{symbol}"],
      ["You pay", "#{F.usd_due(facts.escrow)}, held until a seller sells to you"],
      ["Fills", "Not guaranteed"],
      ["To exercise", F.usd_due(F.total(facts.amount, facts.strike_per_token, unit))],
      break_even(facts.strike_per_token + facts.premium_per_token, symbol),
      ["Opens", F.expiry(facts.expiry)],
      ["Closes", F.window_closes(facts.expiry)]
    ]

  defp facts(:sell_to_bid, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["Calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["Premium", F.usd(facts.premium)],
      ["Fee", F.usd(facts.fee)],
      ["You receive", "#{F.usd(facts.receive)}, paid now"],
      ["If exercised", F.usd(facts.strike)],
      ["Opens", F.expiry(facts.expiry)],
      ["Closes", F.window_closes(facts.expiry)],
      locked(facts.expiry)
    ]

  defp facts(:raise_bid, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["More calls", "#{F.tokens(facts.amount, unit)} #{symbol}"],
      ["You pay", F.usd_due(facts.escrow)]
    ]

  defp facts(:cancel_bid, facts, %{unit: unit, symbol: symbol}),
    do: [
      ["Unsold", "#{F.tokens(facts.unsold, unit)} #{symbol}"],
      ["Freed", F.usd(facts.released)]
    ]

  defp facts(:refund_bid, facts, _assigns), do: [["You receive", F.usd(facts.amount)]]

  # Nothing to collect or stop is said once, as the button's reason, not as a zero.
  defp facts(kind, %{amount: 0}, _assigns) when kind in [:claim, :collect_strike], do: []
  defp facts(:cancel, %{unsold: 0}, _assigns), do: []

  defp facts(:claim, facts, %{unit: unit, symbol: symbol}),
    do: [["You receive", "#{F.tokens(facts.amount, unit)} #{symbol}"]]

  defp facts(:collect_strike, facts, _assigns), do: [["You receive", F.usd(facts.amount)]]

  defp facts(:cancel, facts, %{unit: unit, symbol: symbol}),
    do: [["Unsold", "#{F.tokens(facts.unsold, unit)} #{symbol}"]]

  # A seller's stock under sold calls cannot be taken back or sold until the
  # window has closed, whatever its price does.
  defp locked(expiry), do: ["Locked", "Once sold, until #{F.window_closes(expiry)}"]

  defp break_even(per_token, symbol), do: ["Break-even", "#{F.usd_due(per_token)} per #{symbol}"]

  defp done_lines(:list, facts, %{unit: unit, symbol: symbol}),
    do: [
      "#{F.tokens(facts.amount, unit)} #{symbol} at #{F.usd(facts.strike_per_token)}, #{F.window(facts.expiry)}"
    ]

  defp done_lines(:fill, facts, %{unit: unit, symbol: symbol}),
    do: ["Calls on #{F.tokens(facts.amount, unit)} #{symbol} for #{F.usd_due(facts.premium)}"]

  defp done_lines(:exercise, facts, %{unit: unit, symbol: symbol}),
    do: [
      "#{F.tokens(facts.amount, unit)} #{symbol} for #{F.usd_due(facts.strike)}, ready to collect"
    ]

  defp done_lines(:claim, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.amount, unit)} #{symbol}"]

  defp done_lines(:collect_strike, facts, _assigns), do: [F.usd(facts.amount)]

  defp done_lines(:cancel, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.unsold, unit)} #{symbol} unsold, ready to collect"]

  defp done_lines(:bid, facts, %{unit: unit, symbol: symbol}),
    do: [
      "#{F.tokens(facts.amount, unit)} #{symbol} at #{F.usd(facts.strike_per_token)}, #{F.window(facts.expiry)}"
    ]

  defp done_lines(:sell_to_bid, facts, %{unit: unit, symbol: symbol}),
    do: ["Calls on #{F.tokens(facts.amount, unit)} #{symbol} for #{F.usd(facts.receive)}"]

  defp done_lines(:raise_bid, facts, %{unit: unit, symbol: symbol}),
    do: ["#{F.tokens(facts.amount, unit)} #{symbol} more for #{F.usd_due(facts.escrow)}"]

  defp done_lines(:cancel_bid, facts, _assigns),
    do: ["#{F.usd(facts.released)} ready to refund"]

  defp done_lines(:refund_bid, facts, _assigns), do: [F.usd(facts.amount)]

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

  defp reverted_copy(:fill),
    do: "The purchase did not go through and nothing moved. Someone may have bought these first."

  defp reverted_copy(:sell_to_bid),
    do:
      "The sale did not go through and nothing moved. Someone may have sold into this bid first."

  defp reverted_copy(_kind), do: "That did not go through and nothing moved."

  defp action_label(:list, _symbol), do: "List calls"
  defp action_label(:fill, _symbol), do: "Buy calls"
  defp action_label(:exercise, _symbol), do: "Exercise"
  defp action_label(:cancel, _symbol), do: "Stop selling"
  defp action_label(:claim, symbol), do: "Collect #{symbol}"
  defp action_label(:collect_strike, _symbol), do: "Collect USDC"
  defp action_label(:bid, _symbol), do: "Place bid"
  defp action_label(:sell_to_bid, _symbol), do: "Sell now"
  defp action_label(:raise_bid, _symbol), do: "Raise"
  defp action_label(:cancel_bid, _symbol), do: "Stop"
  defp action_label(:refund_bid, _symbol), do: "Refund"

  defp step_label("stock_approval", %{symbol: symbol}), do: "Approve #{symbol}"
  defp step_label("usdc_approval", _assigns), do: "Approve USDC"
  defp step_label("list", _assigns), do: "Confirm listing"
  defp step_label("fill", _assigns), do: "Confirm purchase"
  defp step_label("exercise", _assigns), do: "Confirm exercise"
  defp step_label("cancel", _assigns), do: "Confirm stop"
  defp step_label(name, _assigns) when name in ~w(claim collect_strike), do: "Confirm collection"
  defp step_label("bid", _assigns), do: "Confirm bid"
  defp step_label("sell_to_bid", _assigns), do: "Confirm sale"
  defp step_label("raise_bid", _assigns), do: "Confirm raise"
  defp step_label("cancel_bid", _assigns), do: "Confirm stop"
  defp step_label("refund_bid", _assigns), do: "Confirm refund"

  defp title(:list), do: "You’re listing"
  defp title(:fill), do: "You’re buying"
  defp title(:exercise), do: "You’re exercising"
  defp title(kind) when kind in [:claim, :collect_strike, :refund_bid], do: "You’re collecting"
  defp title(:bid), do: "You’re bidding"
  defp title(:sell_to_bid), do: "You’re selling"
  defp title(:raise_bid), do: "You’re raising"
  defp title(kind) when kind in [:cancel, :cancel_bid], do: "You’re stopping"

  defp done_title(:list), do: "Listed"
  defp done_title(:fill), do: "Bought"
  defp done_title(:exercise), do: "Exercised"
  defp done_title(:cancel), do: "Stopped"
  defp done_title(kind) when kind in [:claim, :collect_strike], do: "Collected"
  defp done_title(:bid), do: "Bid placed"
  defp done_title(:sell_to_bid), do: "Sold"
  defp done_title(:raise_bid), do: "Raised"
  defp done_title(:cancel_bid), do: "Stopped"
  defp done_title(:refund_bid), do: "Refunded"

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
  defp blocked_words(:not_bidder, _assigns), do: "Only the bidder's wallet can do this"
  defp blocked_words(:bid_expired, _assigns), do: "Bid expired"
  defp blocked_words(:more_than_bid, _assigns), do: "More than the bid wants"

  defp blocked_words(:below_minimum_sale, %{bid: bid, unit: unit, symbol: symbol}),
    do: "Minimum sale #{F.tokens(bid.min_sale, unit)} #{symbol}"

  defp blocked_words(:nothing_to_refund, _assigns), do: "Nothing to refund"

  defp refusal_words(nil), do: nil
  defp refusal_words(:invalid_amount), do: nil
  defp refusal_words(:expiry_not_offered), do: "Choose one of the Friday expiries."
  defp refusal_words(:expiry_passed), do: "That expiry has passed. Choose a later Friday."
  defp refusal_words(:unknown_listing), do: "This listing no longer exists."
  defp refusal_words(:unknown_bid), do: "This bid no longer exists."
  defp refusal_words(:wrong_signer), do: "Use one of your account's own wallets."

  defp refusal_words(_unavailable),
    do: "We couldn't reach Base just now. Try again in a moment."
end
