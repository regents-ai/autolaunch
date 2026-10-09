defmodule AutolaunchWeb.SwapComponent do
  @moduledoc """
  The swap form shared by the token pages and the listing dialogs, for a
  launch on Base or on Robinhood Chain: `launch` names it as the staking card
  does, `symbol` and `image` present its token, `currency` names what the pool
  is entered with (`nil` where the token cannot be swapped here), and
  `start_direction` the side the form opens on (buying unless it says
  `:sell`). With `agent_tools`, the form also answers the page tools that buy
  and sell the page's token (`AutolaunchWeb.AgentPress`). Everything happens on the one form: an amount, a live quote, a
  max-slippage setting behind the gear, then a panel over the form that walks
  the wallet through the swap and closes itself when the swap lands.

  The wallet that acts is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); the balances are that wallet's, or
  the signed-in wallet's while Privy's active wallet is not one of the account's, and a note asks the person to switch while
  the wallet app has another one open.

  Nothing is stored. The quote and the balances are public reads; the review
  lives on this page only, the browser reports a hash and stops, and every
  outcome on screen is the server's own read of that hash against the review
  it was sent from.
  """
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.SwapForm

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Client
  alias Autolaunch.SwapActions
  alias AutolaunchWeb.{AgentPress, OnchainSteps, Paths}
  alias RegentChain.{Presses, Review}

  @default_protection "1"

  @copy %{
    authentication_required: "Sign in to swap from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then review again.",
    invalid_address: "Connect your wallet, then review again.",
    chain_unavailable: "The pool could not be read just now. Try again in a moment.",
    invalid_chain_response: "The pool gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    lab_contract_missing: "Swapping is not available for this token yet.",
    swap_unavailable: "Swapping is not available for this token yet.",
    quote_unavailable: "The pool cannot fill this amount right now. Try a smaller amount.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this token supports.",
    amount_too_large: "That amount is too large to swap at once.",
    amount_above_balance: "This wallet holds less than that.",
    protection_out_of_range: "Max slippage is a number from 1 to 10."
  }

  @generic "That did not go through. Try again in a moment."
  @agent_directions %{"autolaunch_buy" => :buy, "autolaunch_sell" => :sell}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init()
     |> assign(scope: nil, wallet: nil, signer: nil, mismatch: nil, revision: 0)}
  end

  # A review's deadline and allowance window are fifteen minutes long, so it
  # is built again once it is ten minutes old (`OnchainSteps.refresh_later/1`).
  @impl true
  def update(%{refresh_review: review_id}, socket) do
    case socket.assigns.review do
      %{id: ^review_id} -> {:ok, rebuilt(socket, nil)}
      _other -> {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:authenticated, fn -> false end)
      |> assign_new(:current_human_id, fn -> nil end)
      |> assign_new(:session_lease, fn -> nil end)
      |> assign_new(:image, fn -> nil end)
      |> assign_new(:agent_tools, fn -> false end)
      |> assign(read_only?: Autolaunch.Prelaunch.read_only?())
      |> OnchainSteps.adopt()

    scope = {assigns.launch.chain, launch_key(assigns.launch), assigns.currency}

    if socket.assigns.scope == scope,
      do: {:ok, followed(socket)},
      else: {:ok, socket |> fresh(scope) |> followed() |> estimated()}
  end

  defp fresh(socket, scope) do
    socket
    |> assign(
      scope: scope,
      direction: Map.get(socket.assigns, :start_direction, :buy),
      amount: "",
      error: nil,
      estimate: nil,
      protection: @default_protection,
      protection_error: nil,
      options_open: false,
      wallet: nil,
      balances: nil,
      notice: nil,
      swapped: nil
    )
    |> closed()
  end

  # The form follows the wallet that may act. A review is built for one
  # signer, so another one closes it; the balances are that signer's, or the
  # signed-in wallet's while the active wallet is not one of the account's, and another
  # wallet's are never shown as its own.
  defp followed(socket) do
    %{linked: linked, active: active, signed_in: signed_in} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    wallet = OnchainSteps.shown_wallet(linked, signed_in, active)

    socket =
      socket
      |> assign(signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))
      |> reviewed_for_signer(signer)

    if wallet == socket.assigns.wallet,
      do: socket,
      else: socket |> assign(wallet: wallet, balances: nil) |> balanced()
  end

  defp reviewed_for_signer(%{assigns: %{review: %{signer: signer}}} = socket, signer), do: socket
  defp reviewed_for_signer(%{assigns: %{review: nil}} = socket, _signer), do: socket
  defp reviewed_for_signer(socket, _signer), do: closed(socket)

  defp launch_key(%{auction: %{id: id}}), do: id

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="token-swap"
      data-agent-tools={@agent_tools && @currency && "autolaunch_buy autolaunch_sell"}
      phx-hook="OnchainSteps"
    >
      <.swap_done
        :if={@swapped}
        id={"#{@id}-swapped"}
        swapped={@swapped}
        stake_href={@swapped["stake_href"]}
        dismiss_event="dismiss_swapped"
        target={@myself}
      />

      <div :if={@currency} class="token-swap__stack">
        <.swap_form
          id={"#{@id}-form-#{@revision}"}
          sell_symbol={sell(assigns)}
          buy_symbol={buy(assigns)}
          sell_image={if @direction == :sell, do: @image}
          buy_image={if @direction == :buy, do: @image}
          amount={@amount}
          estimated_output={estimate(@estimate, :received)}
          rate={estimate(@estimate, :rate)}
          sell_balance={held(@balances, sold(@direction))}
          buy_balance={held(@balances, bought(@direction))}
          balances_unread={@balances == :unread}
          error={@error || if(is_nil(@review), do: @notice)}
          protection={@protection}
          protection_error={@protection_error}
          options_open={@options_open}
          inert={!is_nil(@review)}
          action={action(assigns)}
          change_event={"form-#{@revision}"}
          submit_event="review_swap"
          reverse_event="reverse"
          options_event="toggle_options"
          fill_event="fill"
          target={@myself}
        />

        <.swap_review
          id={"#{@id}-review"}
          review={@review && @prepared.facts}
          sell_image={if @direction == :sell, do: @image}
          buy_image={if @direction == :buy, do: @image}
          steps={steps(assigns)}
          next_step={next_step(assigns)}
          reverted={reverted(assigns)}
          notice={@press_note}
          close_event="close_review"
          check_event="check_again"
          target={@myself}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
        />
      </div>

      <p :if={!@currency} class="token-swap__rate" role="status">
        Swapping is not available for this token yet.
      </p>
    </div>
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
      do: {:noreply, socket |> entered(params) |> estimated()},
      else: {:noreply, socket}
  end

  def handle_event("toggle_options", _params, socket),
    do: {:noreply, assign(socket, options_open: !socket.assigns.options_open)}

  def handle_event("reverse", _params, socket) do
    {:noreply,
     assign(socket,
       direction: if(socket.assigns.direction == :buy, do: :sell, else: :buy),
       amount: "",
       error: nil,
       estimate: nil,
       notice: nil,
       revision: socket.assigns.revision + 1
     )}
  end

  def handle_event("fill", %{"percent" => percent}, socket)
      when percent in ["25", "50", "75", "100"] do
    case socket.assigns.balances do
      %{} = balances ->
        amount =
          SwapActions.portion(
            Map.fetch!(balances, sold(socket.assigns.direction)),
            String.to_integer(percent)
          )

        {:noreply,
         socket
         |> assign(
           amount: amount,
           error: nil,
           notice: nil,
           revision: socket.assigns.revision + 1
         )
         |> estimated()}

      _unread ->
        {:noreply, socket}
    end
  end

  def handle_event("review_swap", params, socket) do
    case reviewed(socket, params) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  # An agent's press: the next step of the swap open for the same side, amount
  # and slippage, or the first step of a new one, sent at once as the button
  # would.
  def handle_event("agent_press", %{"tool" => tool} = params, socket)
      when is_map_key(@agent_directions, tool) do
    direction = Map.fetch!(@agent_directions, tool)
    input = if is_map(params["input"]), do: params["input"], else: %{}
    fields = %{"amount" => input["amount"], "protection" => input["max_slippage"]}

    case socket.assigns do
      %{read_only?: true} ->
        {:reply, AgentPress.refused("Trading is not open on this site yet."), socket}

      %{authenticated: false} ->
        {:reply, AgentPress.refused(copy(:authentication_required)), socket}

      assigns ->
        case open_step(assigns, direction, fields) do
          %{name: step} -> {:reply, sending(socket, step), socket}
          nil -> agent_reviewed(socket, direction, fields)
        end
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:swap, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  # Closing keeps the entered amount to adjust.
  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_swapped", _params, socket),
    do: {:noreply, assign(socket, swapped: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Reads run off the page's own process, and an answer for a form, wallet or
  # review the page has since left is dropped. A quote or a balance that could
  # not be read says so; a later balance read that fails keeps the last one
  # read for the same wallet.
  @impl true
  def handle_async(:estimate, {:ok, {asked, result}}, socket) do
    if asked == asked(socket) do
      case result do
        {:ok, estimate} -> {:noreply, assign(socket, estimate: estimate)}
        {:error, _unavailable} -> {:noreply, assign(socket, estimate: :unread)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:estimate, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, estimate: :unread)}

  def handle_async(:balances, {:ok, {wallet, read}}, %{assigns: %{wallet: wallet}} = socket) do
    case {read, socket.assigns.balances} do
      {{:ok, balances}, _shown} -> {:noreply, assign(socket, balances: balances)}
      {{:error, _reason}, %{} = _last_read} -> {:noreply, socket}
      {{:error, _reason}, _none} -> {:noreply, assign(socket, balances: :unread)}
    end
  end

  def handle_async(:balances, {:ok, _other_wallet}, socket), do: {:noreply, socket}

  def handle_async(:balances, {:exit, _reason}, socket) do
    if is_map(socket.assigns.balances),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, balances: :unread)}
  end

  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2, &step_reverted/2)}

  def handle_async({:result, hash}, result, socket) do
    logs =
      case result do
        {:ok, {:ok, %{"logs" => logs}}} when is_list(logs) -> logs
        _unread -> nil
      end

    {:noreply, swapped(socket, hash, logs)}
  end

  defp reviewed(socket, params) do
    socket = entered(socket, params)

    request = %{
      launch: socket.assigns.launch,
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      protection: socket.assigns.protection
    }

    with {:ok, socket} <- built(socket, request, nil),
         do: {:ok, assign(socket, swapped: nil, options_open: false)}
  end

  # The review for `request`, with `note` beside its button.
  defp built(socket, request, note) do
    case prepare(socket, request) do
      {:ok, prepared} ->
        review =
          Review.new(socket.assigns.id, socket.assigns.signer, prepared.chain, prepared.steps)

        socket =
          socket
          |> assign(prepared: prepared, request: request, notice: nil, press_note: note)
          |> OnchainSteps.put_review(review)
          |> OnchainSteps.refresh_later()

        {:ok, socket}

      {:error, :no_signer} ->
        {:error, no_signer(socket)}

      {:error, error} ->
        {:error, assign(socket, notice: copy(refusal(error)))}
    end
  end

  # The open swap built again for the amount and slippage it was reviewed
  # with, so its price limit, deadline and allowance window are current: once
  # it is ten minutes old, once an approval lands, and once a step reverts,
  # when `note` says so beside the new button. While a step sent from it is on
  # its way it stays, and a timer asks again later. One that can't be built
  # again stays on the page with the reason beside it.
  defp rebuilt(%{assigns: %{review: review, presses: presses}} = socket, note) do
    if OnchainSteps.pending?(presses, review) do
      OnchainSteps.refresh_later(socket)
    else
      {_built, socket} = built(socket, socket.assigns.request, note)
      socket
    end
  end

  defp prepare(%{assigns: %{signer: nil}}, _request), do: {:error, :no_signer}

  defp prepare(socket, request),
    do: SwapActions.prepare(request, socket.assigns.signer, opts(socket))

  # With no wallet on the account active, the review asks for one; with none
  # connected in this tab, it opens Privy's connect step too.
  defp no_signer(%{assigns: %{linked: nil}} = socket),
    do: assign(socket, notice: copy(:authentication_required))

  defp no_signer(%{assigns: %{active: nil}} = socket),
    do:
      socket
      |> assign(notice: "Connect your wallet, then review again.")
      |> OnchainSteps.connect()

  defp no_signer(socket),
    do:
      assign(socket,
        notice: "Switch to a wallet on your account in your wallet app, then review again."
      )

  defp agent_reviewed(socket, direction, fields) do
    socket = assign(socket, direction: direction, revision: socket.assigns.revision + 1)
    fields = Map.update!(fields, "protection", &(&1 || socket.assigns.protection))

    case reviewed(socket, fields) do
      {:ok, socket} ->
        [%{step: first} | _rest] = socket.assigns.review.steps
        {:reply, sending(socket, first), socket}

      {:error, socket} ->
        {:reply, AgentPress.refused(agent_refusal(socket.assigns)), socket}
    end
  end

  defp sending(%{assigns: %{review: review, prepared: prepared}}, step),
    do: AgentPress.sending(review, step, &step_label(&1, prepared))

  # The step the open swap's button would send, when it is for the same side,
  # amount and slippage (as the form would round it).
  defp open_step(%{review: %{}, prepared: prepared} = assigns, direction, fields) do
    protection =
      case SwapActions.protection(fields["protection"] || assigns.protection) do
        {:ok, bps} -> SwapActions.protection_percent(bps)
        {:error, _out_of_range} -> nil
      end

    same? =
      prepared.context.direction == direction and fields["amount"] == assigns.amount and
        protection == assigns.protection

    if same?, do: pressable(next_step(assigns), steps(assigns))
  end

  defp open_step(_assigns, _direction, _fields), do: nil

  defp agent_refusal(%{protection_error: error}) when is_binary(error), do: error
  defp agent_refusal(%{notice: notice}), do: notice

  defp entered(socket, params) do
    amount = params |> Map.get("amount", socket.assigns.amount) |> limited()
    protection = params |> Map.get("protection", socket.assigns.protection) |> limited()

    error =
      if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
        do: nil,
        else: "Enter an amount using digits and a decimal point."

    socket
    |> assign(amount: amount, error: error, notice: nil)
    |> protected(String.trim(protection))
  end

  defp limited(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp limited(_value), do: ""

  # A usable setting is shown the way it will be applied: rounded to two places.
  defp protected(socket, typed) do
    case SwapActions.protection(typed) do
      {:ok, bps} ->
        assign(socket, protection: SwapActions.protection_percent(bps), protection_error: nil)

      {:error, _out_of_range} ->
        assign(socket,
          protection: typed,
          protection_error: @copy.protection_out_of_range,
          options_open: true
        )
    end
  end

  defp estimated(%{assigns: %{error: nil, amount: amount}} = socket) when amount != "" do
    asked = asked(socket)
    request = %{launch: socket.assigns.launch, direction: asked.direction, amount: amount}

    socket
    |> assign(estimate: nil)
    |> start_async(:estimate, fn -> {asked, SwapActions.estimate(request)} end)
  end

  defp estimated(socket), do: assign(socket, estimate: nil)

  defp estimate(%{} = estimate, field), do: Map.fetch!(estimate, field)
  defp estimate(:unread, :received), do: :unread
  defp estimate(_none, _field), do: nil

  defp asked(socket),
    do: %{
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      revision: socket.assigns.revision
    }

  defp balanced(%{assigns: %{wallet: wallet, currency: currency}} = socket)
       when is_binary(wallet) and is_binary(currency) do
    launch = socket.assigns.launch
    start_async(socket, :balances, fn -> {wallet, SwapActions.balances(launch, wallet)} end)
  end

  defp balanced(socket), do: assign(socket, balances: nil)

  # The swap landed: what it paid is read from its receipt. A landed approval
  # builds the review again, so the swap it leads to carries a fresh deadline.
  defp confirmed(socket, %{name: "swap", hash: hash, review: review}),
    do: start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)

  defp confirmed(%{assigns: %{review: %{id: id}}} = socket, %{review: %{id: id}}),
    do: rebuilt(socket, nil)

  defp confirmed(socket, _earlier_review), do: socket

  defp step_reverted(%{assigns: %{review: %{id: id}}} = socket, %{name: name, review: %{id: id}}),
    do: rebuilt(socket, rebuilt_copy(name))

  defp step_reverted(socket, _earlier_review), do: socket

  # A confirmed swap moved the pool's price, liquidity and fee lanes, so the
  # page reads the pool again, and the balances; a receipt that could not be
  # read leaves out what it paid.
  defp swapped(%{assigns: %{review: %{id: id}, prepared: prepared}} = socket, hash, logs) do
    case Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)) do
      %{review: %{id: ^id, signer: signer}} ->
        send(self(), :reload_pool)

        socket
        |> assign(
          amount: "",
          estimate: nil,
          notice: nil,
          swapped: logs && swap_result(socket, prepared.context, signer, logs)
        )
        |> closed()
        |> balanced()

      _other_review ->
        socket
    end
  end

  defp swapped(socket, _hash, _logs), do: socket

  defp swap_result(socket, %{direction: direction} = context, signer, logs) do
    result = SwapActions.result(context, signer, logs)

    if direction == :buy,
      do: Map.put(result, "stake_href", purchased_stake_path(socket.assigns.launch, result)),
      else: result
  end

  defp closed(socket) do
    socket
    |> assign(
      prepared: nil,
      request: nil,
      press_note: nil,
      revision: socket.assigns.revision + 1
    )
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
  defp action(%{amount: amount, error: nil}) when amount != "", do: :review
  defp action(_assigns), do: :enter_amount

  defp purchased_stake_path(%{chain: :base, auction: auction}, result) do
    case Autolaunch.get_public_token_by_auction(auction.id, load: [:auction]) do
      {:ok, %{auction: auction}} -> stake_path(auction, result)
      _ -> nil
    end
  end

  defp purchased_stake_path(%{chain: :robinhood, auction: auction}, result) do
    case Autolaunch.get_robinhood_auction(auction.auction_address) do
      {:ok, %{token_address: token} = auction} when is_binary(token) ->
        stake_path(auction, result)

      _ ->
        nil
    end
  end

  defp stake_path(auction, result),
    do:
      Paths.token(auction) <>
        "?" <> URI.encode_query(%{stake: result["received_units"]}) <> "#stake"

  defp sell(%{direction: :buy, currency: currency}), do: currency
  defp sell(%{symbol: symbol}), do: symbol
  defp buy(%{direction: :buy, symbol: symbol}), do: symbol
  defp buy(%{currency: currency}), do: currency

  defp sold(:buy), do: :currency
  defp sold(:sell), do: :token
  defp bought(:buy), do: :token
  defp bought(:sell), do: :currency

  defp held(%{} = balances, side), do: Map.fetch!(balances, side).shown
  defp held(_unread, _side), do: nil

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

  defp reverted(%{review: %{}} = assigns) do
    case Enum.find(steps(assigns), &(&1.state == :reverted)) do
      %{name: name} -> reverted_copy(name)
      nil -> nil
    end
  end

  defp reverted(_assigns), do: nil

  defp step_label("token_approval", prepared), do: "Approve #{prepared.facts.sell_symbol}"

  defp step_label("permit2_approval", prepared),
    do: "Allow #{prepared.facts.sell_symbol} for this swap"

  defp step_label("swap", _prepared), do: "Confirm swap"

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp reverted_copy("swap"),
    do:
      "The swap did not go through and nothing was swapped. The price may have moved: close this and review again."

  defp reverted_copy(_approval), do: "That step did not go through. Press again."

  defp rebuilt_copy("swap"),
    do:
      "The swap did not go through and nothing was swapped. This review now uses the current price: press again to send it."

  defp rebuilt_copy(approval), do: reverted_copy(approval)

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  @doc "The currency this token's pool is entered with, or `nil` where it cannot be swapped here."
  def entry_symbol(%{kind: :agent, chain_id: chain_id, quote_token_symbol: "REGENT"}) do
    if base_chain?(chain_id), do: "REGENT"
  end

  def entry_symbol(%{
        kind: :stocks,
        chain_id: chain_id,
        quote_token_address: address,
        quote_token_symbol: symbol
      })
      when is_binary(address) and address != "" and is_binary(symbol) do
    if base_chain?(chain_id) and String.trim(symbol) != "", do: symbol
  end

  def entry_symbol(_auction), do: nil

  defp base_chain?(chain_id), do: chain_id in [8453, Autolaunch.Lab.chain_id()]
end
