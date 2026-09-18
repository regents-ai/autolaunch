defmodule AutolaunchWeb.Components.SwapForm do
  @moduledoc "Presentation shared by token-page and listing-modal swaps. The caller owns all state."

  use Phoenix.Component

  attr :id, :string, required: true
  attr :sell_symbol, :string, required: true
  attr :buy_symbol, :string, required: true
  attr :sell_image, :string, default: nil
  attr :buy_image, :string, default: nil
  attr :amount, :string, required: true
  attr :estimated_output, :string, default: nil
  attr :balance, :string, default: nil
  attr :action_label, :string, required: true
  attr :action_enabled, :boolean, required: true
  attr :disabled_reason, :string, default: nil
  attr :error, :string, default: nil
  attr :status, :string, default: nil
  attr :rate, :string, default: nil
  attr :minimum_received, :string, default: nil
  attr :slippage, :string, default: nil
  attr :network_fee, :string, default: nil
  attr :fee_lines, :list, default: []
  attr :action_href, :string, default: nil
  attr :protection, :string, default: nil
  attr :protection_error, :string, default: nil
  attr :options_open, :boolean, default: false
  attr :options_event, :string, default: nil
  attr :change_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :reverse_event, :string, required: true
  attr :target, :any, default: nil

  def swap_form(assigns) do
    if !assigns.action_enabled &&
         !(is_binary(assigns.disabled_reason) && String.trim(assigns.disabled_reason) != "") do
      raise ArgumentError, "a disabled swap action requires a visible explanation"
    end

    if !Enum.all?(assigns.fee_lines, &is_binary/1) do
      raise ArgumentError, "swap fee lines must be plain text"
    end

    ~H"""
    <section id={@id} class="token-swap" aria-label={"Trade #{@sell_symbol} for #{@buy_symbol}"}>
      <form
        id={@id <> "-form"}
        phx-change={@change_event}
        phx-submit={@submit_event}
        phx-target={@target}
      >
        <div :if={@protection} class="token-swap__options">
          <Regent.Primitives.button
            type="button"
            variant="quiet"
            phx-click={@options_event}
            phx-target={@target}
            aria-expanded={to_string(@options_open)}
            aria-controls={@id <> "-options"}
            aria-label="Trade options"
            title="Trade options"
          >
            <svg viewBox="0 0 24 24" width="20" height="20" fill="none" aria-hidden="true">
              <path
                d="M4 7h10m4 0h2M4 17h2m4 0h10M14 4v6M10 14v6"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
              />
            </svg>
          </Regent.Primitives.button>
        </div>
        <div
          :if={@protection}
          id={@id <> "-options"}
          class="token-swap__options-panel"
          hidden={!@options_open}
        >
          <Regent.Primitives.field
            :let={field}
            id={@id <> "-protection"}
            label="Price protection (%)"
            errors={if @protection_error, do: [@protection_error], else: []}
          >
            <input
              id={field.id}
              name="protection"
              type="text"
              value={@protection}
              inputmode="decimal"
              autocomplete="off"
              spellcheck="false"
              aria-describedby={field.described_by}
              aria-invalid={field.aria_invalid}
              phx-debounce="blur"
            />
            <:hint>
              From 1 to 10. The trade is cancelled if the price moves against you by more than this.
            </:hint>
          </Regent.Primitives.field>
        </div>
        <div class="token-swap__leg">
          <Regent.Primitives.field
            :let={field}
            id={@id <> "-amount"}
            label="Sell"
            errors={if @error, do: [@error], else: []}
            class="token-swap__field"
          >
            <div class="token-swap__amount-row">
              <input
                id={field.id}
                name="amount"
                type="text"
                value={@amount}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                placeholder="0"
                aria-label={"Amount of #{@sell_symbol} to sell"}
                aria-describedby={field.described_by}
                aria-invalid={field.aria_invalid}
                phx-debounce="300"
              />
              <.currency symbol={@sell_symbol} image={@sell_image} />
            </div>
            <:hint :if={@balance}>Balance: {@balance} {@sell_symbol}</:hint>
          </Regent.Primitives.field>
        </div>

        <div class="token-swap__direction">
          <Regent.Primitives.button
            type="button"
            variant="secondary"
            phx-click={@reverse_event}
            phx-target={@target}
            aria-label={"Reverse direction: sell #{@buy_symbol}, buy #{@sell_symbol}"}
            title="Reverse direction"
          >
            <svg viewBox="0 0 24 24" width="24" height="24" fill="none" aria-hidden="true">
              <path d="M12 4v16m-7-7 7 7 7-7" stroke="currentColor" stroke-width="2" />
            </svg>
          </Regent.Primitives.button>
        </div>

        <div class="token-swap__leg token-swap__leg--buy">
          <label for={@id <> "-output"}>Buy</label>
          <div class="token-swap__amount-row">
            <output id={@id <> "-output"} for={@id <> "-amount"} aria-live="polite">
              {if is_nil(@estimated_output), do: "—", else: @estimated_output}
            </output>
            <.currency symbol={@buy_symbol} image={@buy_image} />
          </div>
          <span :if={@estimated_output} class="token-swap__hint">Estimated after swap fees</span>
        </div>

        <.link
          :if={@action_href}
          navigate={@action_href}
          class="rg-button rg-button--primary token-swap__submit"
        >
          <span class="rg-button__label">{@action_label}</span>
        </.link>
        <Regent.Primitives.button
          :if={!@action_href}
          type="submit"
          class="token-swap__submit"
          disabled={!@action_enabled}
          aria-describedby={if !@action_enabled, do: @id <> "-reason"}
        >
          {@action_label}
        </Regent.Primitives.button>
        <p :if={!@action_enabled} id={@id <> "-reason"} class="token-swap__notice" role="status">
          {@disabled_reason}
        </p>
      </form>

      <p :if={@status} class="token-swap__notice" role="status">{@status}</p>
      <p :if={@rate} class="token-swap__rate">{@rate}</p>
      <Regent.Primitives.disclosure
        :if={@minimum_received || @slippage || @network_fee || @fee_lines != []}
        id={@id <> "-details"}
        summary="Swap details"
        class="token-swap__details"
      >
        <dl>
          <div :if={@minimum_received}>
            <dt>Minimum received</dt><dd>{@minimum_received}</dd>
          </div>
          <div :if={@slippage}>
            <dt>Slippage tolerance</dt><dd>{@slippage}</dd>
          </div>
          <div :if={@network_fee}>
            <dt>Network fee</dt><dd>{@network_fee}</dd>
          </div>
        </dl>
        <p :for={line <- @fee_lines}>{line}</p>
      </Regent.Primitives.disclosure>
    </section>
    """
  end

  attr :symbol, :string, required: true
  attr :image, :string, default: nil

  defp currency(assigns) do
    ~H"""
    <span class="token-swap__currency" title={@symbol}>
      <img :if={@image} src={@image} width="28" height="28" alt="" />
      <span>{@symbol}</span>
    </span>
    """
  end
end
