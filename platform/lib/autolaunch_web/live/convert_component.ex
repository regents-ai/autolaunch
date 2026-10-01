defmodule AutolaunchWeb.ConvertComponent do
  @moduledoc """
  The conversion of one memestock launch's REGENT share, on its Base or
  Robinhood token page and on the page that lists every launch: the stock
  waiting in the fee hook's REGENT lane, an amount to sell, and a panel that
  walks the wallet through the reviewed conversion and closes itself when the
  chain confirms it.

  Only a wallet of the signed-in account, and only when the hook names it as its
  executor, sees the form: Privy's active wallet when the account links it
  (`AutolaunchWeb.OnchainSteps`), or the signed-in wallet until Privy reports
  one. The Safe can name another executor at any time, and the pool read
  carries whichever it names now. Every other visitor sees nothing.

  The `launch` assign names the launch: `%{chain: :base, auction: record}` or
  `%{chain: :robinhood, auction: record}`; `pool` is its current facts.
  Nothing is stored: the review lives on this page only, the browser reports a
  hash and stops, and every outcome on screen is the server's own read of it
  against the review it was sent from.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Client
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.{OnchainSteps, StakeComponent, TokenDisplay}
  alias RegentChain.{Address, Presses, Review}

  @copy %{
    authentication_required: "Sign in to convert from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer: "Switch to a wallet on your account in your wallet app, then review again.",
    invalid_address: "Connect your wallet, then review again.",
    chain_unavailable: "The fee contract could not be read just now. Try again in a moment.",
    invalid_chain_response: "The fee contract gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    stake_unavailable: "This launch cannot be read right now.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this stock supports.",
    amount_too_large: "That amount is too large to move at once.",
    not_converter: "Only the wallet chosen to sell REGENT's share can do this.",
    amount_above_share: "Less than that is waiting in REGENT's share.",
    no_route: "This stock has no conversion route yet.",
    price_unavailable:
      "The stock's Chainlink price is not answering right now. Turn off the 95% floor to sell with no minimum, or try again later."
  }
  @generic "That did not go through. Try again in a moment."

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init()
     |> assign(scope: nil, wallet: nil, signer: nil, mismatch: nil, revision: 0)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:title, fn -> "REGENT's share" end)
      |> assign_new(:authenticated, fn -> false end)
      |> assign_new(:current_human_id, fn -> nil end)
      |> assign_new(:session_lease, fn -> nil end)
      |> scoped()
      |> OnchainSteps.adopt()

    {:ok, followed(socket)}
  end

  defp scoped(%{assigns: %{launch: launch, scope: launch}} = socket), do: socket

  defp scoped(socket) do
    socket
    |> assign(scope: socket.assigns.launch, amount: "", floor: true, error: nil, notice: nil)
    |> assign(done: nil)
    |> closed()
  end

  # A review is built for one signer, so another one closes it.
  defp followed(socket) do
    %{linked: linked, active: active, signed_in: signed_in} = socket.assigns
    signer = OnchainSteps.signer(linked, active)

    socket =
      assign(socket,
        signer: signer,
        wallet: signer || signed_in,
        mismatch: OnchainSteps.mismatch_note(linked, active)
      )

    case socket.assigns.review do
      %{signer: ^signer} -> socket
      nil -> socket
      _other_signer -> closed(socket)
    end
  end

  # The hook's element is always present, so the browser's wallet report reaches
  # the card; the form appears only when the signed-in wallet is the converter.
  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap token-stake token-convert"
      phx-hook="OnchainSteps"
      aria-label={@title}
      hidden={!converter?(assigns) && is_nil(@done)}
    >
      <.convert_done :if={@done} id={"#{@id}-done"} done={@done} target={@myself} />

      <div :if={converter?(assigns)} class="token-swap__stack">
        <form
          id={"#{@id}-form-#{@revision}"}
          class="token-swap__form token-stake__form"
          aria-label={"Convert #{@title}"}
          phx-change={"form-#{@revision}"}
          phx-submit="review"
          phx-target={@myself}
          inert={!is_nil(@review)}
        >
          <h2 class="token-stake__title">{@title}</h2>
          <p class="token-stake__lead">
            Sell REGENT's share of this launch's trading fees for {@pool.fees.splitter.dollar.symbol} and send it to REGENT's revenue.
          </p>
          <div class="token-swap__leg">
            <div class="token-swap__leg-head">
              <label for={@id <> "-amount"}>Amount to convert</label>
              <div class="token-swap__portions" role="group" aria-label="Part of REGENT's share">
                <button type="button" phx-click="fill" phx-target={@myself}>Max</button>
              </div>
            </div>
            <div class="token-swap__amount-row">
              <input
                id={@id <> "-amount"}
                name="amount"
                type="text"
                value={@amount}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
                aria-label={"Amount of #{@pool.currency.symbol}"}
                aria-invalid={to_string(!is_nil(@error))}
                phx-debounce="300"
              />
              <span class="token-swap__currency" title={@pool.currency.symbol}>
                <span>{@pool.currency.symbol}</span>
              </span>
            </div>
            <p class="token-swap__leg-foot">
              <span>
                <TokenDisplay.written value={@pool.fees.regent.accrued} unit={@pool.currency.symbol} />
                waiting
              </span>
            </p>
          </div>
          <label class="token-convert__floor">
            <input type="hidden" name="floor" value="false" />
            <input type="checkbox" name="floor" value="true" checked={@floor} />
            <span>
              Refuse less than 95% of the Chainlink price. Leave this off to sell with no minimum, for instance while Chainlink is not answering.
            </span>
          </label>
          <Regent.Primitives.button type="submit" class="token-swap__submit">
            Convert
          </Regent.Primitives.button>
          <p :if={@error || (is_nil(@review) && @notice)} class="token-swap__error" role="alert">
            {@error || @notice}
          </p>
        </form>

        <StakeComponent.stake_review
          id={"#{@id}-review"}
          open={!!@review}
          title="Converting REGENT's share"
          facts={(@review && @prepared.facts) || []}
          steps={steps(assigns)}
          next_step={next_step(assigns)}
          reverted={reverted(assigns)}
          notice={@press_note}
          target={@myself}
          signer={@review && @review.signer}
          chain_name={@review && @review.chain.name}
          mismatch={@mismatch}
        />
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

    {:noreply, followed(socket)}
  end

  def handle_event("form-" <> revision, params, socket) do
    if revision == Integer.to_string(socket.assigns.revision),
      do: {:noreply, entered(socket, params)},
      else: {:noreply, socket}
  end

  def handle_event("fill", _params, socket) do
    {:noreply,
     assign(socket,
       amount: socket.assigns.pool.fees.regent.accrued,
       error: nil,
       notice: nil,
       revision: socket.assigns.revision + 1
     )}
  end

  def handle_event("review", params, socket) do
    socket = entered(socket, params)

    request = %{
      kind: :convert,
      launch: socket.assigns.launch,
      amount: socket.assigns.amount,
      floor: socket.assigns.floor
    }

    case prepare(socket, request) do
      {:ok, prepared} ->
        review =
          Review.new(socket.assigns.id, socket.assigns.signer, prepared.chain, prepared.steps)

        {:noreply,
         socket
         |> assign(prepared: prepared, notice: nil, press_note: nil, done: nil)
         |> OnchainSteps.put_review(review)}

      {:error, error} ->
        {:noreply, assign(socket, notice: copy(refusal(error)))}
    end
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, socket |> OnchainSteps.sent(params) |> assign(notice: nil)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:convert, reason)
        {:noreply, assign(socket, press_note: failure_note(socket.assigns, reason))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &confirmed/2)}

  def handle_async({:result, hash}, result, socket) do
    case {result, socket.assigns.review} do
      {{:ok, {:ok, %{"logs" => logs}}}, %{id: id}} when is_list(logs) ->
        {:noreply, finished(socket, id, hash, logs)}

      {_unread, %{id: id}} ->
        {:noreply, finished(socket, id, hash, nil)}

      {_answer, nil} ->
        {:noreply, socket}
    end
  end

  defp prepare(%{assigns: %{signer: nil}}, _request), do: {:error, :invalid_address}

  defp prepare(socket, request),
    do: StakeActions.prepare(request, socket.assigns.signer, opts(socket))

  defp entered(socket, params) do
    amount = params |> Map.get("amount", socket.assigns.amount) |> limited()

    error =
      if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
        do: nil,
        else: "Enter an amount using digits and a decimal point."

    floor = Map.get(params, "floor", to_string(socket.assigns.floor)) == "true"

    assign(socket, amount: amount, floor: floor, error: error, notice: nil)
  end

  defp limited(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp limited(_value), do: ""

  # The conversion landed: the pool is read again, and what it sold is read
  # from its receipt.
  defp confirmed(socket, %{hash: hash, review: review}) do
    send(self(), :reload_pool)
    start_async(socket, {:result, hash}, fn -> Client.receipt(review.chain, hash) end)
  end

  # The open review closes once its conversion landed; a receipt that could not
  # be read leaves out what it sold.
  defp finished(socket, id, hash, logs) do
    case Enum.find(Presses.shown(socket.assigns.presses), &(&1.hash == hash)) do
      %{review: %{id: ^id}, name: name} ->
        done = if logs, do: StakeActions.result(socket.assigns.prepared.context, name, logs)

        socket
        |> assign(amount: "", notice: nil, done: done || %{})
        |> closed()

      _other_review ->
        socket
    end
  end

  defp closed(socket) do
    socket
    |> assign(prepared: nil, press_note: nil, revision: socket.assigns.revision + 1)
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

  # The form is offered only to the signed-in wallet the hook names as its
  # executor, read from the chain with the pool.
  defp converter?(%{
         authenticated: true,
         wallet: wallet,
         pool: %{kind: :stocks, fees: %{regent: %{converter: converter}}}
       })
       when is_binary(wallet),
       do: Autolaunch.Prelaunch.read_only?() == false and Address.equal?(wallet, converter)

  defp converter?(_assigns), do: false

  defp steps(%{review: nil}), do: []

  defp steps(%{review: review, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: "Confirm conversion", state: step_state(entry), entry: entry}
    end)
  end

  # The step the wallet has not sent from this review yet, or one that did not
  # go through. A sent step moves the button on at once; nothing waits for the
  # network before the next press can reach the wallet.
  defp next_step(%{review: %{}} = assigns),
    do: Enum.find(steps(assigns), &(&1.state in [:ready, :reverted, :other]))

  defp next_step(_assigns), do: nil

  defp step_state(nil), do: :ready

  defp step_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted
  defp step_state(_not_this_step), do: :other

  defp reverted(%{review: %{}} = assigns) do
    if Enum.any?(steps(assigns), &(&1.state == :reverted)), do: reverted_copy()
  end

  defp reverted(_assigns), do: nil

  defp reverted_copy,
    do:
      "The conversion did not go through and nothing moved. The price may have moved since this review. Close this and review again for a fresh price."

  defp copy(reason), do: Map.get(@copy, reason, @generic)

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  attr :id, :string, required: true
  attr :done, :map, required: true
  attr :target, :any, default: nil

  defp convert_done(assigns) do
    ~H"""
    <aside
      id={@id}
      class="token-swap__toast"
      role="status"
      phx-hook="Toast"
      data-variant={AutolaunchWeb.Motion.standard("toast")}
    >
      <div>
        <strong>REGENT's share converted</strong>
        <p :if={@done["converted_units"]}>
          <TokenDisplay.marked
            text={sold_copy(@done)}
            tickers={[@done["currency_symbol"], @done["dollar_symbol"], "REGENT"]}
          />
        </p>
      </div>
      <Regent.Primitives.button
        type="button"
        variant="quiet"
        phx-click="dismiss_done"
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <StakeComponent.cross size="18" />
      </Regent.Primitives.button>
    </aside>
    """
  end

  defp sold_copy(done),
    do:
      "#{done["converted_units"]} #{done["currency_symbol"]} sold for #{done["dollar_units"]} #{done["dollar_symbol"]}, sent to REGENT's revenue"
end
