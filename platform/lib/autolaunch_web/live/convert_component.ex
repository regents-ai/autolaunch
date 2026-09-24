defmodule AutolaunchWeb.ConvertComponent do
  @moduledoc """
  The conversion of one memestock launch's REGENT share, on its Base or
  Robinhood token page and on the page that lists every launch: the stock
  waiting in the fee hook's REGENT lane, an amount to sell, and a panel that
  walks the wallet through the reviewed conversion and closes itself when the
  chain confirms it.

  Only the wallet the hook names as its executor sees the form; the Safe can
  name another at any time, and the pool read carries whichever it names now.
  Every other visitor sees nothing.

  The `launch` assign names the launch: `%{chain: :base, auction: record}` or
  `%{chain: :robinhood, auction: address}`; `pool` is its current facts.
  Nothing is stored: the review lives on this page only, the browser reports a
  hash and stops, and every outcome on screen is the server's own read of it.
  """
  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks.StakeActions
  alias AutolaunchWeb.StakeComponent
  alias Phoenix.LiveView.JS

  @recheck_ms 2_000
  @recheck_limit 90

  @copy %{
    authentication_required: "Sign in to convert from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address: "Connect the wallet you signed in with, then try again.",
    chain_unavailable: "The fee contract could not be read just now. Try again in a moment.",
    invalid_chain_response: "The fee contract gave an incomplete answer. Try again in a moment.",
    lab_config_changed: "The network changed while this was prepared. Try again.",
    stake_unavailable: "This launch cannot be read right now.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this stock supports.",
    amount_too_large: "That amount is too large to move at once.",
    envelope_invalid: "This review is out of date. Close it and review again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity.",
    not_converter: "Only the wallet chosen to sell REGENT's share can do this.",
    amount_above_share: "Less than that is waiting in REGENT's share.",
    no_route: "This stock has no conversion route yet.",
    price_unavailable:
      "The stock's Chainlink price is not answering right now. Turn off the 95% floor to sell with no minimum, or try again later."
  }
  @generic "That did not go through. Try again in a moment."

  @impl true
  def update(assigns, socket) do
    socket =
      if socket.assigns[:scope] == assigns.launch do
        socket
      else
        assign(socket,
          scope: assigns.launch,
          amount: "",
          floor: true,
          error: nil,
          wallet: nil,
          notice: nil,
          review: nil,
          sent: %{},
          done: nil,
          revision: Map.get(socket.assigns, :revision, -1) + 1
        )
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:title, fn -> "REGENT's share" end)
     |> assign_new(:authenticated, fn -> false end)
     |> assign_new(:current_human_id, fn -> nil end)
     |> assign_new(:session_lease, fn -> nil end)}
  end

  # The hook's element is always present, so the page learns the wallet the
  # browser holds; the form appears only when that wallet is the converter.
  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap token-stake token-convert"
      phx-hook="AutolaunchReviewedSteps"
      phx-target={@myself}
      phx-mounted={JS.ignore_attributes(["data-awaiting-wallet"])}
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
              <span>{@pool.fees.regent.accrued} {@pool.currency.symbol} waiting</span>
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
          :if={@review}
          id={"#{@id}-review"}
          title="Converting REGENT's share"
          facts={@review.review}
          steps={steps(@review, @sent)}
          next_step={next_step(@review, @sent)}
          stalled={stalled(@sent)}
          notice={@notice}
          target={@myself}
        />
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

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

    case StakeActions.prepare(request, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(review: review, sent: %{}, notice: nil, done: nil)
         |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: copy(refusal(error)))}
    end
  end

  def handle_event("step_sent", %{"step" => "convert", "transaction_hash" => hash}, socket)
      when is_binary(hash),
      do: {:noreply, checked(socket, hash, 0)}

  def handle_event("check_step", %{"step" => "convert"}, socket) do
    case socket.assigns.sent["convert"] do
      %{hash: hash} -> {:noreply, checked(socket, hash, 0)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: wallet_failure_copy(reason, socket.assigns.review))}

  def handle_event("close_review", _params, socket),
    do: {:noreply, socket |> assign(notice: nil) |> closed()}

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # A recheck for a hash the page has since left is dropped.
  @impl true
  def handle_async(:recheck, {:ok, {hash, attempts, read}}, socket) do
    case socket.assigns.sent["convert"] do
      %{hash: ^hash} -> {:noreply, read(socket, hash, attempts, read)}
      _left -> {:noreply, socket}
    end
  end

  def handle_async(_read, _unavailable, socket), do: {:noreply, socket}

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

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, hash, attempts) do
    read = StakeActions.verify(envelope, :convert, hash, opts(socket))
    read(socket, hash, attempts, read)
  end

  defp checked(socket, _hash, _attempts), do: socket

  # Every figure moved, so the page reads the pool again.
  defp read(socket, hash, attempts, {:ok, %{outcome: :confirmed, result: result}}) do
    send(self(), :reload_pool)

    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, "convert", sent(hash, :confirmed, attempts)),
      amount: "",
      notice: nil,
      done: result
    )
    |> closed()
  end

  defp read(socket, hash, attempts, {:ok, %{outcome: outcome}}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, "convert", sent(hash, outcome, attempts)),
      notice: if(outcome == :reverted, do: reverted_copy())
    )
    |> rechecked()
  end

  # A read that failed is not an answer about the step; it is read again.
  defp read(socket, hash, attempts, {:error, error}) do
    socket
    |> assign(
      sent: Map.put(socket.assigns.sent, "convert", sent(hash, :pending, attempts)),
      notice: if(attempts == 0, do: copy(refusal(error)))
    )
    |> rechecked()
  end

  defp sent(hash, outcome, attempts), do: %{hash: hash, outcome: outcome, attempts: attempts}

  defp rechecked(%{assigns: %{review: %{envelope: envelope}}} = socket) do
    case socket.assigns.sent["convert"] do
      %{outcome: :pending, hash: hash, attempts: attempts} when attempts < @recheck_limit ->
        opts = opts(socket)

        start_async(socket, :recheck, fn ->
          Process.sleep(@recheck_ms)
          {hash, attempts + 1, StakeActions.verify(envelope, :convert, hash, opts)}
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

  # The wallet is only what the browser reports; the review proves it against
  # the session again. A review belongs to the wallet it was made for.
  defp adopt(socket, address) when is_binary(address),
    do: socket |> assign(wallet: String.downcase(address)) |> reviewed_for_wallet()

  defp adopt(socket, _none), do: socket |> assign(wallet: nil) |> reviewed_for_wallet()

  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet, do: socket, else: closed(socket)
  end

  defp reviewed_for_wallet(socket), do: socket

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

  defp steps(review, sent) do
    Enum.map(review.steps, fn %{"step" => name} ->
      %{name: name, label: "Confirm conversion", state: step_state(sent[name])}
    end)
  end

  # The step the wallet has not sent yet, or one that reverted. A sent step
  # moves the button on at once; nothing waits for the network before the next
  # press can reach the wallet.
  defp next_step(review, sent),
    do: Enum.find(steps(review, sent), &(&1.state in [:ready, :reverted]))

  defp stalled(sent) do
    for {name, %{outcome: :pending, attempts: attempts}} <- sent,
        attempts >= @recheck_limit,
        do: name
  end

  defp step_state(nil), do: :ready
  defp step_state(%{outcome: :pending}), do: :sent
  defp step_state(%{outcome: :confirmed}), do: :done
  defp step_state(%{outcome: :reverted}), do: :reverted

  defp reverted_copy,
    do:
      "The conversion did not go through and nothing moved. The price may have moved since this review. Close this and review again for a fresh price."

  defp wallet_failure_copy("wallet_unavailable", _review),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch", %{envelope: %{"chain_id" => chain_id}}) do
    if test_chain?(chain_id),
      do:
        "Your wallet is connected to a different network under this test network's number. Point that network at the test network in your wallet's settings, then try again. Nothing was sent.",
      else:
        "Your wallet is on a different network. Switch it to #{network_name(chain_id)}, then try again. Nothing was sent."
  end

  defp wallet_failure_copy("wallet_declined", _review),
    do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed", _review),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown, _review), do: @generic

  defp test_chain?(chain_id),
    do: Autolaunch.Lab.test_chain?(chain_id) or Autolaunch.Robinhood.Lab.test_chain?(chain_id)

  defp network_name(chain_id) do
    if chain_id == Autolaunch.Robinhood.Lab.chain_id(),
      do: Autolaunch.Robinhood.Lab.network_name(chain_id),
      else: Autolaunch.Lab.network_name(chain_id)
  end

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
    <aside id={@id} class="token-swap__toast" role="status">
      <div>
        <strong>REGENT's share converted</strong>
        <p>
          {sold_copy(@done)}
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
