defmodule AutolaunchWeb.SwapComponent do
  @moduledoc """
  The swap form shared by the token page and the listing dialogs. Everything
  happens on the one form: an amount, a live quote, a max-slippage setting
  behind the gear, then a panel over the form that walks the wallet through the
  swap and closes itself when the swap lands.

  Nothing is stored. The quote and the balances are public reads; the review
  lives on this page only, the browser reports a hash and stops, and every
  outcome on screen is the server's own read of that hash.
  """
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.SwapForm

  alias Autolaunch.Actors.Human
  alias Autolaunch.SwapActions
  alias Phoenix.LiveView.JS

  @default_protection "1"
  # A sent step is read again on its own this often, this many times, before
  # the form offers the read as a button instead.
  @recheck_ms 2_000
  @recheck_limit 90

  @copy %{
    authentication_required: "Sign in to swap from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address: "Connect the wallet you signed in with, then try again.",
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
    protection_out_of_range: "Max slippage is a number from 1 to 10.",
    envelope_invalid: "This swap is out of date. Close it and review again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @steps %{
    "token_approval" => :token_approval,
    "permit2_approval" => :permit2_approval,
    "swap" => :swap
  }

  @impl true
  def update(assigns, socket) do
    auction = assigns.token.auction

    scope =
      {assigns.token.id, auction.kind, auction.chain_id, auction.quote_token_address,
       auction.quote_token_symbol}

    fresh? = socket.assigns[:scope] != scope

    socket =
      if fresh? do
        assign(socket,
          scope: scope,
          direction: :buy,
          amount: Map.get(assigns, :preset_amount) || "",
          error: nil,
          estimate: nil,
          protection: @default_protection,
          protection_error: nil,
          options_open: false,
          wallet: nil,
          balances: nil,
          notice: nil,
          review: nil,
          sent: %{},
          swapped: nil,
          revision: Map.get(socket.assigns, :revision, -1) + 1
        )
      else
        socket
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:authenticated, fn -> false end)
     |> assign_new(:current_human_id, fn -> nil end)
     |> assign_new(:session_lease, fn -> nil end)
     |> assign(
       token_view: Autolaunch.Token.presentation(assigns.token),
       entry_symbol: entry_symbol(auction),
       read_only?: Autolaunch.Prelaunch.read_only?()
     )
     |> then(&if(fresh?, do: estimated(&1), else: &1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="token-swap"
      phx-hook="AutolaunchReviewedSteps"
      phx-target={@myself}
      phx-mounted={JS.ignore_attributes(["data-awaiting-wallet"])}
    >
      <.swap_done
        :if={@swapped}
        id={"#{@id}-swapped"}
        swapped={@swapped}
        dismiss_event="dismiss_swapped"
        target={@myself}
      />

      <div :if={@entry_symbol} class="token-swap__stack">
        <.swap_form
          id={"#{@id}-form-#{@revision}"}
          sell_symbol={sell(assigns)}
          buy_symbol={buy(assigns)}
          sell_image={if @direction == :sell, do: @token_view.image}
          buy_image={if @direction == :buy, do: @token_view.image}
          amount={@amount}
          estimated_output={@estimate && @estimate.received}
          rate={@estimate && @estimate.rate}
          sell_balance={held(@balances, sold(@direction))}
          buy_balance={held(@balances, bought(@direction))}
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
          :if={@review}
          id={"#{@id}-review"}
          review={@review.review}
          sell_image={if @direction == :sell, do: @token_view.image}
          buy_image={if @direction == :buy, do: @token_view.image}
          steps={steps(@review, @sent)}
          next_step={next_step(@review, @sent)}
          stalled={stalled(@sent)}
          notice={@notice}
          close_event="close_review"
          check_event="check_step"
          target={@myself}
        />
      </div>

      <p :if={!@entry_symbol} class="token-swap__rate" role="status">
        Swapping is not available for this token yet.
      </p>
    </div>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

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

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("review_swap", params, socket) do
    socket = entered(socket, params)

    request = %{
      auction: socket.assigns.token.auction,
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      protection: socket.assigns.protection
    }

    case SwapActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(review: review, sent: %{}, notice: nil, swapped: nil, options_open: false)
         |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: copy(refusal(error)))}
    end
  end

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, checked(socket, name, hash, 0)}

  def handle_event("check_step", %{"step" => name}, socket) do
    case socket.assigns.sent[name] do
      %{hash: hash} -> {:noreply, checked(socket, name, hash, 0)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: wallet_failure_copy(reason))}

  # Closing keeps the entered amount to adjust.
  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_swapped", _params, socket),
    do: {:noreply, assign(socket, swapped: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # Reads run off the page's own process, and an answer for a form, wallet or
  # sent step the page has since left is dropped.
  @impl true
  def handle_async(:estimate, {:ok, {asked, result}}, socket) do
    if asked == asked(socket) do
      case result do
        {:ok, estimate} -> {:noreply, assign(socket, estimate: estimate)}
        {:error, _unavailable} -> {:noreply, assign(socket, estimate: nil)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async(:balances, {:ok, {wallet, {:ok, balances}}}, socket) do
    if wallet == socket.assigns.wallet,
      do: {:noreply, assign(socket, balances: balances)},
      else: {:noreply, socket}
  end

  def handle_async({:recheck, name}, {:ok, {hash, attempts, read}}, socket) do
    case socket.assigns.sent[name] do
      %{hash: ^hash} -> {:noreply, read(socket, name, hash, attempts, read)}
      _left -> {:noreply, socket}
    end
  end

  def handle_async(_read, _unavailable, socket), do: {:noreply, socket}

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
    request = %{auction: socket.assigns.token.auction, direction: asked.direction, amount: amount}

    socket
    |> assign(estimate: nil)
    |> start_async(:estimate, fn -> {asked, SwapActions.estimate(request)} end)
  end

  defp estimated(socket), do: assign(socket, estimate: nil)

  defp asked(socket),
    do: %{
      direction: socket.assigns.direction,
      amount: socket.assigns.amount,
      revision: socket.assigns.revision
    }

  defp balanced(%{assigns: %{wallet: wallet, entry_symbol: symbol}} = socket)
       when is_binary(wallet) and is_binary(symbol) do
    auction = socket.assigns.token.auction
    start_async(socket, :balances, fn -> {wallet, SwapActions.balances(auction, wallet)} end)
  end

  defp balanced(socket), do: assign(socket, balances: nil)

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash, attempts) do
    read = SwapActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket))
    read(socket, name, hash, attempts, read)
  end

  defp checked(socket, _name, _hash, _attempts), do: socket

  # A confirmed swap moved the pool's price, liquidity and fee lanes, so the
  # page reads the pool again.
  defp read(socket, "swap", _hash, _attempts, {:ok, %{outcome: :confirmed, result: result}}) do
    send(self(), :reload_pool)

    socket
    |> assign(amount: "", estimate: nil, notice: nil, swapped: result)
    |> closed()
    |> balanced()
  end

  defp read(socket, name, hash, attempts, {:ok, %{outcome: outcome}}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, name, sent(hash, outcome, attempts)),
      notice: if(outcome == :reverted, do: reverted_copy(name))
    )
    |> rechecked(name)
  end

  # A read that failed is not an answer about the step; it is read again.
  defp read(socket, name, hash, attempts, {:error, error}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, name, sent(hash, :pending, attempts)),
      notice: if(attempts == 0, do: copy(refusal(error)))
    )
    |> rechecked(name)
  end

  defp sent(hash, outcome, attempts), do: %{hash: hash, outcome: outcome, attempts: attempts}

  # Nothing waits on this: it only saves the person pressing "check again"
  # while the network includes what the wallet already sent.
  defp rechecked(%{assigns: %{review: %{envelope: envelope}}} = socket, name) do
    case socket.assigns.sent[name] do
      %{outcome: :pending, hash: hash, attempts: attempts} when attempts < @recheck_limit ->
        step = Map.fetch!(@steps, name)
        opts = opts(socket)

        start_async(socket, {:recheck, name}, fn ->
          Process.sleep(@recheck_ms)
          {hash, attempts + 1, SwapActions.verify(envelope, step, hash, opts)}
        end)

      _settled ->
        socket
    end
  end

  defp closed(socket) do
    socket
    |> assign(review: nil, sent: %{}, revision: socket.assigns.revision + 1)
    |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp published(%{assigns: %{review: %{envelope: envelope, steps: steps}}} = socket) do
    push_event(socket, "reviewed-steps:review", %{
      component_id: socket.assigns.id,
      signer: envelope["expected_signer"],
      chain_id: envelope["chain_id"],
      lab: envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: envelope["arguments"]["block_number"],
        block_hash: envelope["arguments"]["block_hash"]
      },
      steps: Enum.map(steps, &Map.take(&1, ["step", "to", "data"]))
    })
  end

  # The wallet is only what the browser reports; every read that matters proves
  # it against the session again. A review belongs to the wallet it was made for.
  defp adopt(socket, nil),
    do: socket |> assign(wallet: nil) |> reviewed_for_wallet() |> balanced()

  defp adopt(socket, address) when is_binary(address),
    do: socket |> assign(wallet: String.downcase(address)) |> reviewed_for_wallet() |> balanced()

  defp adopt(socket, _other), do: socket

  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet, do: socket, else: closed(socket)
  end

  defp reviewed_for_wallet(socket), do: socket

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp action(%{read_only?: true}), do: :closed
  defp action(%{authenticated: false}), do: :sign_in
  defp action(%{wallet: nil}), do: :connect_wallet
  defp action(%{amount: amount, error: nil}) when amount != "", do: :review
  defp action(_assigns), do: :enter_amount

  defp sell(%{direction: :buy, entry_symbol: symbol}), do: symbol
  defp sell(%{token_view: %{symbol: symbol}}), do: symbol
  defp buy(%{direction: :buy, token_view: %{symbol: symbol}}), do: symbol
  defp buy(%{entry_symbol: symbol}), do: symbol

  defp sold(:buy), do: :currency
  defp sold(:sell), do: :token
  defp bought(:buy), do: :token
  defp bought(:sell), do: :currency

  defp held(nil, _side), do: nil
  defp held(balances, side), do: Map.fetch!(balances, side).shown

  defp steps(review, sent) do
    Enum.map(review.steps, fn %{"step" => name} ->
      %{name: name, label: step_label(name, review), state: step_state(sent[name])}
    end)
  end

  # One button at a time: the first step the wallet has not sent yet, or one
  # that reverted. A sent step moves the button on at once; nothing waits for
  # the network before the next press can reach the wallet.
  defp next_step(review, sent) do
    Enum.find(steps(review, sent), &(&1.state in [:ready, :reverted]))
  end

  defp stalled(sent) do
    for {name, %{outcome: :pending, attempts: attempts}} <- sent,
        attempts >= @recheck_limit,
        do: name
  end

  defp step_label("token_approval", review), do: "Approve #{review.review.sell_symbol}"

  defp step_label("permit2_approval", review),
    do: "Allow #{review.review.sell_symbol} for this swap"

  defp step_label("swap", _review), do: "Confirm swap"

  defp step_state(nil), do: :ready
  defp step_state(%{outcome: :pending}), do: :sent
  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted

  defp reverted_copy("swap"),
    do:
      "The swap did not go through and nothing was swapped. The price may have moved: close this and review again."

  defp reverted_copy(_approval), do: "That step did not go through. Try it again."

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under this test network's number. Point that network at the test network in your wallet's settings, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

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
