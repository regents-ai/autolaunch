defmodule AutolaunchWeb.SubjectWalletComponent do
  @moduledoc """
  The Make a payment card on a Revstake token's page: pay into the token's
  revenue split, or route a balance already waiting at its payment address.
  Staking and claiming live in the token page's own staking card.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); its balances show, or the signed-in
  wallet's until Privy reports the active one, and a note names both while the
  wallet app has another wallet open. The review is prepared on the server and
  lives on this page only: an exact approval when one is missing, then the
  payment. Every press reaches the wallet, and every outcome is the server's
  own read of the hash against the review it was sent from.
  """

  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.StepState

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Client
  alias Autolaunch.SubjectWalletActions
  alias AutolaunchWeb.Components.SwapForm
  alias AutolaunchWeb.{OnchainSteps, TokenDisplay}
  alias RegentChain.{Presses, Review}

  @assets [
    %{id: "usdc", key: :usdc},
    %{id: "regent", key: :regent},
    %{id: "subject", key: :subject}
  ]

  @copy %{
    authentication_required: "Sign in to use your wallet here.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then press again.",
    invalid_address: "Connect your wallet, then press again.",
    chain_unavailable: "Base could not be read just now. Try again in a moment.",
    subject_not_found: "Payments are not open on this token yet.",
    subject_unavailable: "This token could not be read just now.",
    subject_not_on_base: "This token is not on Base.",
    subject_token_unavailable: "Payments are not open on this token yet.",
    subject_splitter_unavailable: "This token is not sharing revenue yet.",
    subject_treasury_unavailable: "This token has no treasury yet.",
    canonical_receiver_unavailable: "This token has no payment address yet.",
    receiver_not_canonical: "This payment address is not the launch's own. Nothing was prepared.",
    splitter_subject_mismatch: "This token's revenue split does not match it.",
    splitter_usdc_mismatch: "This token's revenue split does not match it.",
    splitter_regent_mismatch: "This token's revenue split does not match it.",
    splitter_treasury_mismatch: "This token's revenue split does not match its treasury.",
    receiver_splitter_mismatch: "This payment address does not belong to this token.",
    receiver_subject_mismatch: "This payment address does not belong to this token.",
    receiver_usdc_mismatch: "This payment address does not belong to this token.",
    receiver_regent_mismatch: "This payment address does not belong to this token.",
    receiver_treasury_mismatch: "This payment address does not belong to this token.",
    subject_wallet_preparation_unavailable: "Payments are not open on this token yet.",
    amount_above_balance: "That is more than this wallet holds.",
    nothing_to_sweep: "There is nothing waiting at the payment address right now.",
    invalid_amount: "Enter an amount using this asset's decimal places.",
    unsupported_asset: "Choose one of the listed assets."
  }

  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init(&followed/1)
     |> assign(
       signer: nil,
       mismatch: nil,
       prepared: nil,
       reviews: %{},
       state: nil,
       state_for: nil,
       asset: "usdc",
       amount: "",
       notice: nil,
       routed: nil,
       assets: @assets
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> OnchainSteps.adopt() |> followed() |> read_state()}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, steps: steps(assigns))

    ~H"""
    <section
      id={@id}
      class="subject-wallet rg-panel rg-panel--surface"
      phx-hook="OnchainSteps"
      aria-labelledby={@id <> "-title"}
    >
      <header class="subject-wallet-heading">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id={@id <> "-title"}>Make a payment</h2>
        </Regent.Structure.section_bar>
        <p>
          Pay into <span class="ticker">{@symbol}</span>'s revenue split. Part goes to everyone staking
          <span class="ticker">{@symbol}</span>
          and the rest
          to its treasury. Your wallet confirms every step.
        </p>
      </header>

      <p class="subject-wallet-notice" role="status" hidden={!@notice}>{@notice}</p>

      <p :if={!@authenticated} class="subject-wallet-empty">
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          Sign in to pay
        </Regent.Primitives.button>
      </p>

      <div :if={@authenticated && @state} class="subject-wallet-body">
        <dl class="subject-wallet-balances" hidden={!!@review}>
          <div>
            <dt>Wallet</dt>
            <dd class="subject-wallet-mono">{RegentFormat.short_address(@state.signer)}</dd>
          </div>
          <div :for={asset <- @assets}>
            <dt>{asset_label(asset.key, @symbol)}</dt>
            <dd>{@state.balances[asset.key]}</dd>
          </div>
        </dl>

        <form
          id={"#{@id}-form"}
          hidden={!!@review}
          class="subject-wallet-choose"
          phx-change="subject_form_changed"
          phx-submit="review_subject_action"
          phx-target={@myself}
        >
          <div class="subject-wallet-field rg-field">
            <label for={"#{@id}-asset"}>Asset</label>
            <select id={"#{@id}-asset"} name="asset">
              <option :for={asset <- @assets} value={asset.id} selected={asset.id == @asset}>
                {asset_label(asset.key, @symbol)}
              </option>
            </select>
          </div>

          <div class="subject-wallet-field rg-field">
            <label for={"#{@id}-amount"}>Amount</label>
            <div class="subject-wallet-amount">
              <input
                id={"#{@id}-amount"}
                name="amount"
                value={@amount}
                inputmode="decimal"
                autocomplete="off"
                placeholder="0.0"
              />
              <Regent.Primitives.button
                type="button"
                phx-click="fill_subject_amount"
                phx-target={@myself}
                variant="secondary"
              >
                Max
              </Regent.Primitives.button>
            </div>
          </div>

          <p :if={@state.receiver} class="subject-wallet-hint">
            Payment address {RegentFormat.short_address(@state.receiver.address)}
          </p>
          <p class="onchain-note" role="status" hidden={!@mismatch}>{@mismatch}</p>

          <Regent.Primitives.button
            class="subject-wallet-primary"
            type="submit"
            name="kind"
            value="pay"
            disabled={@amount == ""}
          >
            Review payment
          </Regent.Primitives.button>

          <div :if={@state.receiver} class="subject-wallet-waiting">
            <p class="subject-wallet-hint">
              Waiting at the payment address: {waiting(@state.receiver, @asset)} {asset_label(
                asset_key(@asset),
                @symbol
              )}. Anyone can route it into the revenue split. You pay only the network fee, and
              nothing is sent to your wallet.
            </p>
            <Regent.Primitives.button type="submit" name="kind" value="sweep" variant="secondary">
              Route waiting {asset_label(asset_key(@asset), @symbol)}
            </Regent.Primitives.button>
          </div>
        </form>

        <%!-- The review stays in the page and is only hidden, so its wallet
             button is never replaced while a person presses it. --%>
        <section
          id={"#{@id}-review"}
          class="subject-wallet-review"
          aria-label="Payment review"
          hidden={!@review}
        >
          <%= if @review do %>
            <h3>{title(@prepared.facts.kind)}</h3>
            <dl>
              <div>
                <dt>You pay</dt>
                <dd>
                  <TokenDisplay.written
                    value={@routed || @prepared.facts.amount}
                    unit={asset_label(@prepared.facts.asset, @symbol)}
                  />
                </dd>
              </div>
              <div>
                <dt>You get</dt>
                <dd>Nothing back. This goes into the revenue split.</dd>
              </div>
              <div>
                <dt>Wallet</dt>
                <dd class="subject-wallet-mono">{RegentFormat.short_address(@review.signer)}</dd>
              </div>
              <div>
                <dt>Network</dt>
                <dd>{@review.chain.name}</dd>
              </div>
            </dl>

            <%!-- What this transaction is about to divide. Once it settles, its own
                event says what really moved, so the estimate stops speaking. --%>
            <p class="subject-wallet-share" hidden={!!@routed}>
              <TokenDisplay.marked
                text={share_copy(@prepared.facts, @symbol)}
                tickers={[@symbol, "USDC", "REGENT"]}
              />
            </p>

            <p :if={@prepared.facts.kind == :sweep} class="subject-wallet-share">
              This pays the network fee to move that balance on. Nothing is sent to your wallet, and
              someone else routing it first can make this fail.
            </p>
          <% end %>

          <%!-- The list styling drops list semantics, so the role is stated. --%>
          <ol class="subject-wallet-steps" role="list" aria-label="Payment progress">
            <li :for={step <- @steps} data-step={step.name}>
              <span>
                <TokenDisplay.marked text={step.label} tickers={[@symbol, "USDC", "REGENT"]} />
              </span>
              <.step_state state={chip(step)} />
              <span class="subject-wallet-mono" hidden={!step.entry}>
                {step.entry && RegentFormat.short_hash(step.entry.hash)}
              </span>
            </li>
          </ol>

          <p class="subject-wallet-settled" role="status" hidden={!@routed}>
            {@routed && @prepared &&
              "Routed #{@routed} #{asset_label(@prepared.facts.asset, @symbol)} into the revenue split."}
          </p>
          <p
            class="subject-wallet-settled"
            role="status"
            aria-live="polite"
            hidden={!progress_copy(@steps, @review)}
          >
            {progress_copy(@steps, @review)}
          </p>
          <p class="subject-wallet-notice" role="status" hidden={!@press_note}>{@press_note}</p>
          <SwapForm.wallet_step
            next_step={next_step(@steps)}
            steps={@steps}
            reverted={reverted(@steps)}
            signer={@review && @review.signer}
            chain_name={@review && @review.chain.name}
            mismatch={@mismatch}
            check_event="check_again"
            target={@myself}
          />
          <Regent.Primitives.button
            type="button"
            phx-click="cancel_subject_wallet_review"
            phx-target={@myself}
            variant="secondary"
            hidden={!cancellable?(@steps)}
          >
            Cancel
          </Regent.Primitives.button>
          <Regent.Primitives.button
            type="button"
            phx-click="clear_subject_wallet_action"
            phx-target={@myself}
            variant="secondary"
            hidden={!finished?(@steps)}
          >
            Make another payment
          </Regent.Primitives.button>
        </section>
      </div>
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

    {:noreply, socket |> followed() |> read_state()}
  end

  def handle_event("subject_form_changed", params, socket) do
    {:noreply,
     assign(socket,
       amount: Map.get(params, "amount", socket.assigns.amount),
       asset: Map.get(params, "asset", socket.assigns.asset),
       notice: nil
     )}
  end

  def handle_event("fill_subject_amount", _params, socket),
    do: {:noreply, assign(socket, amount: maximum(socket.assigns), notice: nil)}

  def handle_event("review_subject_action", params, socket) do
    case action_kind(params["kind"]) do
      nil -> {:noreply, socket}
      kind -> {:noreply, review(socket, kind, form_params(socket.assigns, params))}
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:subject, reason)
        %{linked: linked, active: active, review: review} = socket.assigns
        chain_name = review && review.chain.name
        note = OnchainSteps.failure_note(reason, linked, active, chain_name)
        {:noreply, assign(socket, press_note: note)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("cancel_subject_wallet_review", _params, socket),
    do: {:noreply, withdrawn(socket)}

  def handle_event("clear_subject_wallet_action", _params, socket),
    do: {:noreply, socket |> assign(amount: "", routed: nil) |> withdrawn() |> reread()}

  @impl true
  def handle_async(:state, {:ok, {wallet, result}}, socket) do
    cond do
      wallet != shown_wallet(socket.assigns) -> {:noreply, socket}
      match?({:ok, _state}, result) -> {:noreply, assign(socket, state: elem(result, 1))}
      true -> {:noreply, assign(socket, state: nil, notice: copy(refusal(elem(result, 1))))}
    end
  end

  def handle_async(:state, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, notice: @generic)}

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  def handle_async({:result, hash}, result, socket) do
    logs =
      case result do
        {:ok, {:ok, %{"logs" => logs}}} when is_list(logs) -> logs
        _unread -> nil
      end

    {:noreply, routed(socket, hash, logs)}
  end

  # The wallet that may act, and the balances the card shows.

  # A review is built for one signer, so an unsent review for another one is
  # dropped.
  defp followed(socket) do
    %{linked: linked, active: active, presses: presses, review: review} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    socket = assign(socket, signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))

    cond do
      is_nil(review) -> socket
      review.signer == signer -> socket
      started?(presses, review) -> socket
      true -> withdrawn(socket)
    end
  end

  defp shown_wallet(%{signer: signer}) when is_binary(signer), do: signer
  defp shown_wallet(%{active: nil, signed_in: signed_in}), do: signed_in
  defp shown_wallet(_assigns), do: nil

  # The balances of the wallet shown, read in the background whenever that
  # wallet changes and after a payment.
  defp read_state(socket) do
    wallet = shown_wallet(socket.assigns)

    cond do
      !socket.assigns.authenticated -> socket
      is_nil(wallet) -> assign(socket, state: nil, state_for: nil)
      wallet == socket.assigns.state_for -> socket
      true -> start_state(socket, wallet)
    end
  end

  defp reread(socket) do
    case shown_wallet(socket.assigns) do
      nil -> socket
      wallet -> start_state(socket, wallet)
    end
  end

  defp start_state(socket, wallet) do
    subject_id = socket.assigns.subject_id
    opts = opts(socket)

    socket
    |> assign(state_for: wallet)
    |> start_async(:state, fn ->
      {wallet, SubjectWalletActions.wallet_state(subject_id, wallet, opts)}
    end)
  end

  # Reviews

  # With no wallet that may act nothing is prepared: with no active wallet
  # Privy's connect step opens, and with another wallet open the note beside
  # the button names both.
  defp review(%{assigns: %{signer: nil, active: nil}} = socket, _kind, _params),
    do: socket |> assign(notice: nil) |> OnchainSteps.connect()

  defp review(%{assigns: %{signer: nil}} = socket, _kind, _params),
    do: assign(socket, notice: copy(:wrong_signer))

  defp review(%{assigns: %{signer: signer}} = socket, kind, params) do
    case SubjectWalletActions.prepare(
           socket.assigns.subject_id,
           signer,
           kind,
           params,
           opts(socket)
         ) do
      {:ok, prepared} ->
        review = Review.new(socket.assigns.id, signer, prepared.chain, prepared.steps)

        socket
        |> assign(
          prepared: prepared,
          routed: nil,
          notice: nil,
          press_note: nil,
          reviews: Map.put(socket.assigns.reviews, review.id, prepared)
        )
        |> OnchainSteps.put_review(review)

      {:error, error} ->
        assign(socket, notice: copy(refusal(error)))
    end
  end

  defp withdrawn(socket), do: socket |> assign(prepared: nil) |> OnchainSteps.put_review(nil)

  # Outcomes

  # A confirmed payment is read from its receipt; an approval needs nothing
  # more, since the payment's button is already on the page.
  defp confirmed(socket, %{name: "action", hash: hash, review: review}),
    do: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)

  defp confirmed(socket, _approval), do: socket

  defp routed(socket, hash, logs) do
    with %{review: %{id: id}} <-
           Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)),
         %{facts: facts} <- Map.get(socket.assigns.reviews, id) do
      socket
      |> assign(routed: logs && SubjectWalletActions.result(facts, logs))
      |> reread()
    else
      _other -> socket
    end
  end

  # Steps

  defp steps(%{review: %{} = review, prepared: prepared, presses: presses, symbol: symbol}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)

      %{
        name: name,
        label: step_label(name, prepared.facts, symbol),
        state: state(entry),
        entry: entry
      }
    end)
  end

  defp steps(_assigns), do: []

  defp started?(presses, review),
    do: Enum.any?(review.steps, &OnchainSteps.entry(presses, review, &1.step))

  # One button at a time: the first step the wallet has not sent from this
  # review yet, or one that did not go through. A sent approval moves the
  # button on to the payment at once.
  defp next_step(steps), do: Enum.find(steps, &(&1.state in [:ready, :reverted, :other]))

  defp state(nil), do: :ready

  defp state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp state(%{outcome: :confirmed}), do: :done
  defp state(%{outcome: :reverted}), do: :reverted
  defp state(_not_this_step), do: :other

  defp chip(%{state: :ready}), do: "Ready"
  defp chip(%{state: state}) when state in [:sent, :stalled], do: "Sent"
  defp chip(%{state: :done}), do: "Confirmed"
  defp chip(%{state: :reverted}), do: "Reverted"
  defp chip(%{state: :other}), do: "Unresolved"

  defp finished?([]), do: false
  defp finished?(steps), do: Enum.all?(steps, &(&1.state == :done))

  defp cancellable?([]), do: false

  defp cancellable?(steps),
    do: not finished?(steps) and not Enum.any?(steps, &(&1.state in [:sent, :stalled]))

  defp progress_copy(steps, review) do
    case steps |> Enum.filter(&(&1.state in [:sent, :stalled, :other])) |> List.last() do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "#{review.chain.name} has not confirmed this yet. Check again, or look in your wallet activity."

      %{name: "approval"} ->
        "Allowing the spend…"

      %{name: _action} ->
        "Paying into the revenue split…"

      nil ->
        nil
    end
  end

  defp reverted(steps) do
    case Enum.find(steps, &(&1.state == :reverted)) do
      %{name: "approval"} ->
        "That approval did not go through. Only the network fee was spent. Press again."

      %{} ->
        "That did not go through, so nothing moved. Only the network fee was spent. Press again."

      nil ->
        nil
    end
  end

  defp step_label("approval", facts, symbol),
    do: "Allow #{asset_label(facts.asset, symbol)} to be spent"

  defp step_label("action", facts, _symbol), do: title(facts.kind)

  defp title(:pay), do: "Pay"
  defp title(:sweep), do: "Route the waiting balance"

  # The one economic sentence a payment review owes the customer: the exact
  # amounts this inflow divides into as staking stands at review, never a share
  # or a rounded estimate. Stakers are paid for the stake they hold against the
  # whole token supply, so their part stays small until much of that supply is
  # staked, and the treasury takes the remainder. The split is settled by the
  # contract when the payment is mined, so the sentence says which figures the
  # reviewed moment fixes and which it does not.
  defp share_copy(%{allocation: allocation, asset: asset}, symbol) do
    %{gross: gross, skim: skim, net: net, stakers: stakers, treasury: treasury} = allocation
    shown = &"#{SubjectWalletActions.units(&1, asset)} #{asset_label(asset, symbol)}"

    "Of this #{shown.(gross)}, #{shown.(skim)} goes to the protocol. As things stand right now, the remaining #{shown.(net)} divides into #{shown.(stakers)} for everyone staking #{symbol} and #{shown.(treasury)} for its treasury. If staking changes before this goes through, those last two amounts change with it."
  end

  # The closed set this card maps a browser value through. Nothing here builds
  # an atom from what the browser sent: a value outside the set has no meaning
  # and is answered with nothing rather than with an error.
  defp action_kind("pay"), do: :pay
  defp action_kind("sweep"), do: :sweep
  defp action_kind(_unknown), do: nil

  defp asset_key(id), do: Enum.find_value(@assets, &(&1.id == id && &1.key))

  defp asset_label(:subject, symbol), do: symbol
  defp asset_label(:usdc, _symbol), do: "USDC"
  defp asset_label(:regent, _symbol), do: "REGENT"

  defp form_params(assigns, params) do
    %{
      "asset" => Map.get(params, "asset", assigns.asset),
      "amount" => Map.get(params, "amount", assigns.amount)
    }
  end

  defp maximum(%{asset: asset, state: %{balances: balances}}),
    do: Map.get(balances, asset_key(asset), "")

  defp maximum(_assigns), do: ""

  defp waiting(receiver, asset), do: Map.get(receiver.balances, asset_key(asset))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil
end
