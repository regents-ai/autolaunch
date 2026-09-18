defmodule AutolaunchWeb.Components.SwapForm do
  @moduledoc """
  Presentation shared by token-page and listing-dialog swaps: the one form, and
  the panel that opens over it while the wallet finishes the swap. The caller
  owns all state.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :sell_symbol, :string, required: true
  attr :buy_symbol, :string, required: true
  attr :sell_image, :string, default: nil
  attr :buy_image, :string, default: nil
  attr :amount, :string, required: true
  attr :estimated_output, :string, default: nil
  attr :sell_balance, :string, default: nil
  attr :buy_balance, :string, default: nil
  attr :rate, :string, default: nil
  attr :error, :string, default: nil
  attr :protection, :string, required: true
  attr :protection_error, :string, default: nil
  attr :options_open, :boolean, default: false
  attr :inert, :boolean, default: false

  attr :action, :atom,
    required: true,
    values: [:enter_amount, :review, :sign_in, :connect_wallet, :closed]

  attr :change_event, :string, required: true
  attr :submit_event, :string, required: true
  attr :reverse_event, :string, required: true
  attr :options_event, :string, required: true
  attr :fill_event, :string, required: true
  attr :target, :any, default: nil

  def swap_form(assigns) do
    ~H"""
    <form
      id={@id}
      class="token-swap__form"
      aria-label={"Swap #{@sell_symbol} for #{@buy_symbol}"}
      phx-change={@change_event}
      phx-submit={@submit_event}
      phx-target={@target}
      inert={@inert}
    >
      <header class="token-swap__bar">
        <span class="token-swap__mode">Swap</span>
        <Regent.Primitives.button
          type="button"
          variant="quiet"
          class="token-swap__gear"
          phx-click={@options_event}
          phx-target={@target}
          aria-expanded={to_string(@options_open)}
          aria-controls={@id <> "-options"}
          aria-label="Swap settings"
          title="Swap settings"
        >
          <svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true">
            <path d="M19.43 12.98a7.8 7.8 0 0 0 0-1.96l2.11-1.65a.5.5 0 0 0 .12-.64l-2-3.46a.5.5 0 0 0-.61-.22l-2.49 1a7.3 7.3 0 0 0-1.69-.98l-.38-2.65A.49.49 0 0 0 14 2h-4a.49.49 0 0 0-.49.42l-.38 2.65c-.61.25-1.17.58-1.69.98l-2.49-1a.5.5 0 0 0-.61.22l-2 3.46a.49.49 0 0 0 .12.64l2.11 1.65a7.9 7.9 0 0 0 0 1.96l-2.11 1.65a.5.5 0 0 0-.12.64l2 3.46c.12.22.39.3.61.22l2.49-1c.52.4 1.08.73 1.69.98l.38 2.65c.04.24.25.42.49.42h4c.24 0 .45-.18.49-.42l.38-2.65c.61-.25 1.17-.58 1.69-.98l2.49 1c.22.08.49 0 .61-.22l2-3.46a.5.5 0 0 0-.12-.64l-2.11-1.65ZM12 15.5A3.5 3.5 0 1 1 12 8.5a3.5 3.5 0 0 1 0 7Z" />
          </svg>
        </Regent.Primitives.button>
        <div id={@id <> "-options"} class="token-swap__popover" hidden={!@options_open}>
          <div class="token-swap__slippage">
            <label for={@id <> "-protection"}>Max slippage</label>
            <span class="token-swap__slippage-field">
              <input
                id={@id <> "-protection"}
                name="protection"
                type="text"
                value={@protection}
                inputmode="decimal"
                autocomplete="off"
                spellcheck="false"
                aria-invalid={to_string(!is_nil(@protection_error))}
                aria-describedby={if @protection_error, do: @id <> "-protection-error"}
                phx-debounce="blur"
              />
              <span aria-hidden="true">%</span>
            </span>
          </div>
          <p
            :if={@protection_error}
            id={@id <> "-protection-error"}
            class="token-swap__error"
            role="alert"
          >
            {@protection_error}
          </p>
        </div>
      </header>

      <div class="token-swap__leg">
        <div class="token-swap__leg-head">
          <label for={@id <> "-amount"}>Sell</label>
          <div
            :if={@sell_balance}
            class="token-swap__portions"
            role="group"
            aria-label="Sell part of your balance"
          >
            <button
              :for={{label, percent} <- [{"25%", 25}, {"50%", 50}, {"75%", 75}, {"Max", 100}]}
              type="button"
              phx-click={@fill_event}
              phx-value-percent={percent}
              phx-target={@target}
            >
              {label}
            </button>
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
            aria-label={"Amount of #{@sell_symbol} to sell"}
            aria-invalid={to_string(!is_nil(@error))}
            phx-debounce="300"
          />
          <.currency symbol={@sell_symbol} image={@sell_image} />
        </div>
        <p class="token-swap__leg-foot">
          <span :if={@sell_balance}>{@sell_balance} {@sell_symbol}</span>
        </p>
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
        <div class="token-swap__leg-head">
          <label for={@id <> "-output"}>Buy</label>
        </div>
        <div class="token-swap__amount-row">
          <output
            id={@id <> "-output"}
            for={@id <> "-amount"}
            aria-live="polite"
            data-empty={is_nil(@estimated_output)}
          >
            {@estimated_output || "0"}
          </output>
          <.currency symbol={@buy_symbol} image={@buy_image} />
        </div>
        <p class="token-swap__leg-foot">
          <span :if={@buy_balance}>{@buy_balance} {@buy_symbol}</span>
        </p>
      </div>

      <Regent.Primitives.button
        :if={@action == :enter_amount}
        type="submit"
        variant="secondary"
        class="token-swap__submit token-swap__submit--idle"
      >
        Enter an amount
      </Regent.Primitives.button>
      <Regent.Primitives.button :if={@action == :review} type="submit" class="token-swap__submit">
        Review
      </Regent.Primitives.button>
      <Regent.Primitives.button
        :if={@action == :sign_in}
        type="button"
        class="token-swap__submit"
        data-account-target="sign-in"
      >
        Sign in
      </Regent.Primitives.button>
      <Regent.Primitives.button
        :if={@action == :connect_wallet}
        type="button"
        class="token-swap__submit"
        data-wallet-connect
      >
        Connect wallet
      </Regent.Primitives.button>
      <Regent.Primitives.button
        :if={@action == :closed}
        type="button"
        variant="secondary"
        class="token-swap__submit token-swap__submit--idle"
        disabled
      >
        Trading opens after launch
      </Regent.Primitives.button>

      <p :if={@error} class="token-swap__error" role="alert">{@error}</p>
      <p :if={@rate} class="token-swap__rate">{@rate}</p>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :review, :map, required: true
  attr :sell_image, :string, default: nil
  attr :buy_image, :string, default: nil

  attr :steps, :list,
    required: true,
    doc: "%{name, label, state}, state one of :ready, :sent, :done, :reverted"

  attr :next_step, :map, default: nil
  attr :stalled, :list, default: []
  attr :notice, :string, default: nil
  attr :close_event, :string, required: true
  attr :check_event, :string, required: true
  attr :target, :any, default: nil

  def swap_review(assigns) do
    ~H"""
    <section id={@id} class="token-swap__review" aria-labelledby={@id <> "-title"}>
      <header class="token-swap__review-head">
        <h3 id={@id <> "-title"}>You’re swapping</h3>
        <Regent.Primitives.button
          type="button"
          variant="quiet"
          phx-click={@close_event}
          phx-target={@target}
          aria-label="Close"
          title="Close"
        >
          <.cross size="20" />
        </Regent.Primitives.button>
      </header>

      <div class="token-swap__review-side">
        <p>{@review.pay} {@review.sell_symbol}</p>
        <img :if={@sell_image} src={@sell_image} width="36" height="36" alt="" />
      </div>
      <svg
        class="token-swap__review-arrow"
        viewBox="0 0 24 24"
        width="20"
        height="20"
        fill="none"
        aria-hidden="true"
      >
        <path d="M12 4v16m-7-7 7 7 7-7" stroke="currentColor" stroke-width="2" />
      </svg>
      <div class="token-swap__review-side">
        <p>{@review.receive} {@review.buy_symbol}</p>
        <img :if={@buy_image} src={@buy_image} width="36" height="36" alt="" />
      </div>

      <dl class="token-swap__review-facts">
        <div>
          <dt>Max slippage</dt>
          <dd>{@review.protection}%</dd>
        </div>
        <div>
          <dt>Receive at least</dt>
          <dd>{@review.minimum} {@review.buy_symbol}</dd>
        </div>
      </dl>

      <p class="token-swap__review-rule"><span>Continue in your wallet</span></p>

      <ol class="token-swap__steps" role="list">
        <li
          :for={{step, index} <- Enum.with_index(@steps, 1)}
          data-step={step.name}
          data-state={step.state}
          data-current={@next_step && @next_step.name == step.name}
        >
          <span class="token-swap__step-mark" aria-hidden="true"></span>
          <span>{step.label}</span>
          <span class="token-swap__step-note">
            {step_note(step, index, length(@steps), @next_step)}
          </span>
        </li>
      </ol>

      <Regent.Primitives.button
        :if={@next_step}
        type="button"
        class="token-swap__submit token-swap__wallet-step"
        data-reviewed-step={@next_step.name}
      >
        <span class="token-swap__wallet-step-label">{@next_step.label}</span>
        <span class="token-swap__wallet-step-wait">
          <span class="token-swap__spinner" aria-hidden="true"></span> Confirm in wallet
        </span>
      </Regent.Primitives.button>
      <Regent.Primitives.button
        :for={name <- @stalled}
        type="button"
        variant="secondary"
        class="token-swap__submit"
        phx-click={@check_event}
        phx-value-step={name}
        phx-target={@target}
      >
        Check again
      </Regent.Primitives.button>

      <p :if={@notice} class="token-swap__error" role="alert">{@notice}</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :swapped, :map, required: true
  attr :dismiss_event, :string, required: true
  attr :target, :any, default: nil

  def swap_done(assigns) do
    ~H"""
    <aside id={@id} class="token-swap__toast" role="status">
      <div>
        <strong>Swapped</strong>
        <p>
          {@swapped["paid_units"]} {@swapped["sell_symbol"]} for {@swapped["received_units"]} {@swapped[
            "buy_symbol"
          ]}
        </p>
      </div>
      <Regent.Primitives.button
        type="button"
        variant="quiet"
        phx-click={@dismiss_event}
        phx-target={@target}
        aria-label="Dismiss"
        title="Dismiss"
      >
        <.cross size="18" />
      </Regent.Primitives.button>
    </aside>
    """
  end

  defp step_note(%{state: :done}, _index, _count, _next), do: "Done"
  defp step_note(%{state: :sent}, _index, _count, _next), do: "Waiting for the network"
  defp step_note(%{state: :reverted}, _index, _count, _next), do: "Did not go through"

  defp step_note(%{name: name}, index, count, %{name: name}) when count > 1,
    do: "Step #{index} of #{count}"

  defp step_note(_step, _index, _count, _next), do: nil

  attr :size, :string, required: true

  defp cross(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" width={@size} height={@size} fill="none" aria-hidden="true">
      <path d="M6 6l12 12M18 6 6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round" />
    </svg>
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
