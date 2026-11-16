defmodule AutolaunchWeb.EarnComponent do
  @moduledoc """
  The wallet panel for one Earn product: the wallet's balance in the market
  and its USDC, an amount with Max, and the Deposit or Withdraw button, which
  opens a review over the panel with the steps the wallet sends, one button at
  a time, the way covered calls' panels work. The review closes when the chain
  confirms the last step, and the page then says what moved (`toast/1`, from
  `{:earn_done, done}`).

  The page passes `product`, `decimals` (the asset's, from the catalog),
  `kind` (`:deposit` or `:withdraw`, the page's tabs), `reads` (how many times
  the page has read the market), the panel's `session_lease` and
  `current_human_id`. A landed step leaves the market's shared reading behind
  and every open page of the product hears it, once for each transaction
  (`Autolaunch.Earn.SharedTerms.changed/2`), so each reads the market again.
  A transaction the panel already follows, reported again, starts no second
  check, and Check again reads only a step the page stopped reading.

  The server builds every step (`Autolaunch.Earn.prepare_earn_steps/4`, the
  same action agents call) for the wallet that may act
  (`AutolaunchWeb.OnchainSteps`), and every press of the wallet button goes
  straight to the wallet. A deposit's approval is its own step; one the chain
  already holds shows as done. The button is disabled only when the chain, read
  at the latest block for the amount as it stands, makes the step certain to
  fail, with the reason beside it. That preview is read again, at the latest
  block, each time the amount settles (a moment after the last key), the
  wallet or the tab changes, the page comes back into view, a press goes out,
  a step lands on this page or another, and each time the page reads the
  market (its Refresh included), so the button comes back once the chain
  allows the step; nothing else, a render of the page included, reads it
  again. A new preview stops the one still being read and drops the one
  before, so the button is never held by a reason from before while the chain
  is read again, nor disabled because a preview is under way. An amount that
  does not read is said under the field and never disables anything.

  Max fills in the wallet's USDC for a deposit. For a withdrawal it asks for
  everything, which withdraws the balance as it stands when the step lands; a
  typed figure, even one equal to the balance, is that figure only. Another
  wallet starts from an empty amount, Max off.

  The figures beside the field (Balance, Wallet) are shortened and never
  rounded up (`amount/3`); the review and what the page says moved give the
  exact amount.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Earn
  alias Autolaunch.Earn.{Amount, Answer, SharedTerms}
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
       quoted_for: nil,
       refusal: nil,
       reviewed: nil,
       landed: MapSet.new(),
       openings: 0,
       notice: nil,
       mismatch: nil,
       wallet: nil,
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

  def handle_event("change", params, socket),
    do: {:noreply, socket |> typed(params["amount"]) |> assign(notice: nil) |> sync()}

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

  # A transaction the panel already follows is being read, or has been: told of
  # it again, the panel starts no second check.
  def handle_event("step_sent", params, socket) do
    if followed?(socket.assigns.presses, params["transaction_hash"]),
      do: {:noreply, socket},
      else: {:noreply, socket |> OnchainSteps.sent(params) |> assign(notice: nil)}
  end

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

  # Check again reads a step the page stopped reading, as the button offering
  # it is shown for. A step still being read, one that landed, or a hash that
  # names no step sent from here, whatever it is, is left as it is.
  def handle_event("check_again", params, socket) do
    if stalled?(socket.assigns.presses, params["hash"]),
      do: {:noreply, OnchainSteps.check_again(socket, params["hash"])},
      else: {:noreply, socket}
  end

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  @impl true
  def handle_async(
        :quote,
        {:ok, {{{:ok, request}, signer, _reads, _held_reads} = key, result}},
        %{assigns: %{quoted_for: key}} = socket
      ) do
    case result do
      {:ok, prepared} ->
        {:noreply, assign(socket, quote: {request, signer, prepared}, refusal: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, quote: nil, refusal: reason)}
    end
  end

  # A preview for figures the panel has since moved on from.
  def handle_async(:quote, {:ok, _earlier}, socket), do: {:noreply, socket}

  # A preview stopped for a newer one, or because the amount no longer reads.
  def handle_async(:quote, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

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

  # Whether the panel follows transaction `hash` already (`Presses.sent/2`
  # keeps it lowercase).
  defp followed?(presses, hash) when is_binary(hash),
    do: Enum.any?(Presses.shown(presses), &(&1.hash == String.downcase(hash)))

  defp followed?(_presses, _hash), do: false

  # Whether the step sent as `hash` is one the page stopped reading.
  defp stalled?(presses, hash) when is_binary(hash),
    do: Enum.any?(Presses.shown(presses), &(&1.hash == hash and Presses.stalled?(&1)))

  defp stalled?(_presses, _hash), do: false

  # The figures follow the wallet that may act and the amount as it stands.
  defp sync(socket) do
    signer = signer(socket)
    socket = follow(socket, signer)
    %{reads: reads, held_reads: held_reads} = socket.assigns

    socket
    |> preview({request(socket.assigns), signer, reads, held_reads})
    |> assign(mismatch: OnchainSteps.mismatch_note(socket.assigns.linked, socket.assigns.active))
    |> read_held()
  end

  # The preview for the amount (its tab included), the wallet that may act and
  # the readings as they stand (`quoted_for`), read only when one of them
  # changed. A new one stops the one still being read and drops the one
  # before, so until it arrives nothing holds the button.
  defp preview(%{assigns: %{quoted_for: key}} = socket, key), do: socket

  defp preview(socket, {request, signer, _reads, _held_reads} = key) do
    socket = socket |> cancel_async(:quote) |> assign(quoted_for: key, quote: nil, refusal: nil)

    case request do
      {:ok, request} when is_binary(signer) ->
        id = socket.assigns.current_human_id
        start_async(socket, :quote, fn -> {key, prepare(id, request, signer)} end)

      _no_preview ->
        socket
    end
  end

  # Another wallet that may act starts from an empty amount, Max off, and the
  # review open for the one before closes: its figures and steps were for that
  # wallet only. The first wallet the panel hears of keeps what was typed.
  defp follow(%{assigns: %{wallet: signer}} = socket, signer), do: socket
  defp follow(%{assigns: %{wallet: nil}} = socket, signer), do: assign(socket, wallet: signer)

  defp follow(socket, signer),
    do: socket |> assign(wallet: signer, text: "", max: false, notice: nil) |> closed()

  # What the wallet the panel shows figures for holds, for the balance and Max:
  # read again for each new wallet, each ask of the panel's own (`held_reads`)
  # and each reading of the market the page takes (`reads`). Another wallet
  # shows nothing until its own figures are read. A new ask stops the read
  # still running for an earlier one, so asks never stack.
  defp read_held(%{assigns: assigns} = socket) do
    wallet =
      if is_list(assigns.linked),
        do: OnchainSteps.shown_wallet(assigns.linked, assigns.signed_in, assigns.active)

    key = {wallet, assigns.held_reads, assigns.reads}
    %{product: product, current_human_id: id} = assigns

    cond do
      key == assigns.held_for ->
        socket

      is_nil(wallet) ->
        socket |> cancel_async(:held) |> assign(held_for: key, held: nil)

      true ->
        socket
        |> assign(
          held_for: key,
          held: if(match?({^wallet, _, _}, assigns.held_for), do: assigns.held)
        )
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

  # A step landed: every open page of the product reads the market again, this
  # one included, and with it each panel its wallet and its preview (`reads`),
  # once for each transaction. When every step of the open review has landed
  # once, whichever press of it landed, the review closes and the page says
  # what moved.
  defp confirmed(socket, %{review: %{id: id}, name: name, hash: hash}) do
    SharedTerms.changed(socket.assigns.product.id, hash)

    case socket.assigns.review do
      %{id: ^id} ->
        socket = assign(socket, landed: MapSet.put(socket.assigns.landed, name))

        if Enum.all?(steps(socket.assigns), &(&1.state == :done)),
          do: finished(socket),
          else: socket

      _other_review ->
        socket
    end
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
                  maxlength="32"
                  phx-debounce="300"
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

  @doc """
  An amount of the asset as Earn's figures show it: shortened, and cut, never
  rounded up (`RegentFormat.token_amount/2`), so a figure never shows more than
  is there.
  """
  def amount(units, decimals, asset),
    do: RegentFormat.token_amount(units, decimals) <> " " <> asset

  # The market's rate in the words the page gives it beside its terms.
  defp rate_words(rate),
    do: "#{Answer.yearly_percent(rate)}% a year at today's rate, before compounding. It changes."

  # The exact amount, every digit, where a person confirms money or is told it moved.
  defp exact(units, decimals, asset), do: Amount.text(units, decimals) <> " " <> asset

  defp facts(%{kind: :deposit} = prepared, decimals) do
    [
      ["Amount", exact(prepared.units, decimals, prepared.product.asset)],
      ["Market", prepared.product.market],
      ["Rate", rate_words(prepared.terms.rate)]
    ]
  end

  defp facts(%{kind: :withdraw, withdrawal: :everything} = prepared, decimals) do
    [
      ["Amount", "All, #{exact(prepared.units, decimals, prepared.product.asset)} now"],
      ["Market", prepared.product.market],
      ["To", "This wallet"]
    ]
  end

  defp facts(%{kind: :withdraw} = prepared, decimals) do
    [
      ["Amount", exact(prepared.units, decimals, prepared.product.asset)],
      ["Market", prepared.product.market],
      ["To", "This wallet"]
    ]
  end

  defp done_line(%{kind: :deposit} = prepared, decimals),
    do:
      "#{exact(prepared.units, decimals, prepared.product.asset)} is earning in #{prepared.product.market}."

  defp done_line(%{kind: :withdraw, withdrawal: :everything}, _decimals),
    do: "Your whole balance is back in your wallet."

  defp done_line(%{kind: :withdraw} = prepared, decimals),
    do: "#{exact(prepared.units, decimals, prepared.product.asset)} is back in your wallet."

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

  # Each refusal a preview or review for a wallet of the panel's own can meet.
  # Its amount always reads within the bound, its product is the catalog's and
  # its signer is one of the account's wallets as the panel read them, a whole
  # address, so `invalid_request`, `unknown_product`, `invalid_amount` and
  # `wallet_required` cannot.
  defp refusal_words(:wrong_signer), do: "Use one of your account's own wallets."
  defp refusal_words(:authentication_required), do: "Sign in again to use your wallet here."
  defp refusal_words(:earn_unavailable), do: "Earn is not available right now. Try again later."

  defp refusal_words(:chain_unavailable),
    do: "We couldn't reach Base just now. Try again in a moment."

  defp refusal_words(:invalid_chain_response),
    do: "Base sent an answer we couldn't read. Try again in a moment."

  defp refusal_words(:invalid_block_header),
    do: "Base sent a block we couldn't read. Try again in a moment."

  defp refusal_words(:wrong_chain),
    do: "Our connection to Base answered for another network. Try again in a moment."
end
