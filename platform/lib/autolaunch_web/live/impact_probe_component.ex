defmodule AutolaunchWeb.ImpactProbeComponent do
  @moduledoc """
  The token page's price check: a trade size in the pool's currency, quoted
  fresh both ways at the latest block (`Autolaunch.SwapActions.impact/1`).
  Each quote goes through the pool and its fee hook as a real swap would, so
  the gap from the pool's price includes every fee. Nothing is sent or signed
  from here; the swap form is where a trade happens.
  """
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.SwapActions
  alias AutolaunchWeb.TokenDisplay

  @copy %{
    chain_unavailable: "The pool could not be read just now. Try again in a moment.",
    invalid_chain_response: "The pool gave an incomplete answer. Try again in a moment.",
    swap_unavailable: "Quotes are not available for this token yet.",
    lab_contract_missing: "Quotes are not available for this token yet.",
    quote_unavailable: "The pool cannot fill this amount right now. Try a smaller amount.",
    amount_required: "Enter an amount above zero.",
    invalid_amount: "Enter an amount above zero.",
    invalid_decimal: "Enter an amount above zero.",
    amount_not_representable: "That amount has more decimal places than this currency supports.",
    amount_too_large: "That amount is too large to quote at once."
  }
  @generic "The quote did not come back. Try again in a moment."

  @impl true
  def mount(socket), do: {:ok, assign(socket, amount: "", result: nil, notice: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="token-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="token-next-card__head">
        <h2 id={"#{@id}-title"}>
          <.info_tip
            id={"#{@id}-tip"}
            text="Fresh quotes from the pool for buying and for selling the same size, run through the pool and its fee hook as a real swap would be. The gap from the pool's price includes every fee."
          >
            Price impact
          </.info_tip>
        </h2>
      </header>
      <form
        id={"#{@id}-form"}
        class="token-next-probe__form"
        phx-change="probe"
        phx-submit="probe"
        phx-target={@myself}
      >
        <label for={"#{@id}-amount"}>Trade size</label>
        <div class="token-next-probe__input">
          <input
            id={"#{@id}-amount"}
            name="amount"
            type="text"
            inputmode="decimal"
            autocomplete="off"
            placeholder="0.0"
            value={@amount}
            phx-debounce="400"
          />
          <span>{@pool.currency.symbol}</span>
        </div>
        <button type="submit" class="token-next-probe__again">Quote again</button>
      </form>
      <div class="token-next-probe__sides">
        <div :for={{side, title} <- [buy: "Buy", sell: "Sell"]} class="token-next-probe__side">
          <h3>{title}</h3>
          <dl class="token-next-rows">
            <div>
              <dt>You pay</dt>
              <dd>{figure(@result, side, :pay, pay_unit(side, @pool))}</dd>
            </div>
            <div>
              <dt>You get</dt>
              <dd>{figure(@result, side, :get, get_unit(side, @pool))}</dd>
            </div>
            <div>
              <dt>Per {@pool.token.symbol}</dt>
              <dd>{figure(@result, side, :price, @pool.currency.symbol)}</dd>
            </div>
            <div>
              <dt>{if side == :buy, do: "Above the pool price", else: "Below the pool price"}</dt>
              <dd>{cost(@result, side)}</dd>
            </div>
          </dl>
        </div>
      </div>
      <p class="token-next-source" role="status">
        {status(@notice, @result, @pool)}
      </p>
    </section>
    """
  end

  @impl true
  def handle_event("probe", %{"amount" => amount}, socket) when is_binary(amount) do
    amount = amount |> String.slice(0, 256) |> String.trim()
    request = %{launch: socket.assigns.launch, amount: amount}

    if amount == "",
      do: {:noreply, assign(socket, amount: "", result: nil, notice: nil)},
      else:
        {:noreply,
         socket
         |> assign(amount: amount, notice: nil)
         |> start_async(:impact, fn -> {amount, SwapActions.impact(request)} end)}
  end

  @impl true
  def handle_async(:impact, {:ok, {amount, read}}, %{assigns: %{amount: amount}} = socket) do
    case read do
      {:ok, result} -> {:noreply, assign(socket, result: result, notice: nil)}
      {:error, error} -> {:noreply, assign(socket, result: nil, notice: copy(error))}
    end
  end

  def handle_async(:impact, {:ok, _older_amount}, socket), do: {:noreply, socket}

  def handle_async(:impact, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, result: nil, notice: @generic)}

  defp figure(nil, _side, _field, _unit), do: "—"

  defp figure(result, side, field, unit) do
    assigns = %{amount: result |> Map.fetch!(side) |> Map.fetch!(field), unit: unit}

    ~H"""
    <TokenDisplay.tokens amount={@amount} unit={@unit} />
    """
  end

  defp cost(nil, _side), do: "—"
  defp cost(result, side), do: result |> Map.fetch!(side) |> Map.fetch!(:cost) |> Kernel.<>("%")

  defp pay_unit(:buy, pool), do: pool.currency.symbol
  defp pay_unit(:sell, pool), do: pool.token.symbol
  defp get_unit(:buy, pool), do: pool.token.symbol
  defp get_unit(:sell, pool), do: pool.currency.symbol

  defp status(nil, nil, pool),
    do: "Enter a size in #{pool.currency.symbol} to quote a buy and a sell of the same worth."

  defp status(nil, result, pool),
    do:
      "Quoted at block #{grouped(result.block)}, against a pool price of #{result.price} #{pool.currency.symbol}."

  defp status(notice, _result, _pool), do: notice

  defp copy(%Ash.Error.Invalid.Unavailable{reason: reason}), do: Map.get(@copy, reason, @generic)
  defp copy(%{errors: errors}), do: Enum.find_value(errors, @generic, &reason_copy/1)
  defp copy(_other), do: @generic

  defp reason_copy(%Ash.Error.Invalid.Unavailable{reason: reason}),
    do: Map.get(@copy, reason, @generic)

  defp reason_copy(_other), do: nil

  defp grouped(number), do: Autolaunch.Stocks.Amounts.grouped(Integer.to_string(number))
end
