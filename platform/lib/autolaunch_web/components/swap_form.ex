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

  attr :estimated_output, :any,
    default: nil,
    doc: "the quoted amount, `nil` before one arrives, or `:unread` when the pool gave none"

  attr :sell_balance, :string, default: nil
  attr :buy_balance, :string, default: nil
  attr :balances_unread, :boolean, default: false
  attr :rate, :string, default: nil
  attr :error, :string, default: nil
  attr :protection, :string, required: true
  attr :protection_error, :string, default: nil
  attr :options_open, :boolean, default: false
  attr :inert, :boolean, default: false

  attr :action, :atom,
    required: true,
    values: [:enter_amount, :review, :sign_in, :closed]

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
        <div
          id={@id <> "-options"}
          class="token-swap__popover"
          hidden={!@options_open}
          {AutolaunchWeb.Motion.panel("menu")}
        >
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
          <span :if={@sell_balance}><AutolaunchWeb.TokenDisplay.written
            value={@sell_balance}
            unit={@sell_symbol}
          /></span>
          <span :if={@balances_unread}>Your balance can't be read right now</span>
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
            data-empty={!is_binary(@estimated_output)}
          >
            {output(@estimated_output)}
          </output>
          <.currency symbol={@buy_symbol} image={@buy_image} />
        </div>
        <p class="token-swap__leg-foot">
          <span :if={@buy_balance}><AutolaunchWeb.TokenDisplay.written
            value={@buy_balance}
            unit={@buy_symbol}
          /></span>
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
  attr :review, :map, default: nil, doc: "the reviewed facts; nil while no swap is reviewed"
  attr :sell_image, :string, default: nil
  attr :buy_image, :string, default: nil

  attr :steps, :list,
    required: true,
    doc:
      "%{name, label, state, entry}, state one of :ready, :sent, :stalled, :done, :reverted, :other"

  attr :next_step, :map, default: nil
  attr :reverted, :string, default: nil
  attr :notice, :string, default: nil
  attr :close_event, :string, required: true
  attr :check_event, :string, required: true
  attr :target, :any, default: nil
  attr :signer, :string, default: nil
  attr :chain_name, :string, default: nil
  attr :mismatch, :string, default: nil

  @doc """
  The review panel over the swap form. It stays in the page and is only
  hidden while no swap is reviewed, so its wallet button is never replaced.
  """
  def swap_review(assigns) do
    ~H"""
    <section
      id={@id}
      class="token-swap__review"
      aria-labelledby={@id <> "-title"}
      hidden={!@review}
    >
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

      <%= if @review do %>
        <div class="token-swap__review-side">
          <p>
            <span class="token-swap__review-label">You pay</span>
            <AutolaunchWeb.TokenDisplay.written value={@review.pay} unit={@review.sell_symbol} />
          </p>
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
          <p>
            <span class="token-swap__review-label">You get about</span>
            <AutolaunchWeb.TokenDisplay.written value={@review.receive} unit={@review.buy_symbol} />
          </p>
          <img :if={@buy_image} src={@buy_image} width="36" height="36" alt="" />
        </div>

        <dl class="token-swap__review-facts">
          <div>
            <dt>Max slippage</dt>
            <dd><span class="figure__value">{@review.protection}%</span></dd>
          </div>
          <div>
            <dt>Receive at least</dt>
            <dd>
              <AutolaunchWeb.TokenDisplay.written value={@review.minimum} unit={@review.buy_symbol} />
            </dd>
          </div>
          <div>
            <dt>Already in the quote</dt>
            <dd class="token-swap__review-fees">
              <span :for={fee <- @review.fees}>{fee}</span>
            </dd>
          </div>
        </dl>
      <% end %>

      <p class="token-swap__review-rule"><span>Continue in your wallet</span></p>

      <ol class="token-swap__steps" role="list">
        <li
          :for={{step, index} <- Enum.with_index(@steps, 1)}
          data-step={step.name}
          data-state={step.state}
          data-current={@next_step && @next_step.name == step.name}
        >
          <span class="token-swap__step-mark" aria-hidden="true"></span>
          <span>
            <AutolaunchWeb.TokenDisplay.marked
              text={step.label}
              tickers={[@review.sell_symbol, @review.buy_symbol]}
            />
          </span>
          <span class="token-swap__step-note">
            {step_note(step, index, length(@steps), @next_step)}
          </span>
        </li>
      </ol>

      <.wallet_step
        next_step={@next_step}
        steps={@steps}
        reverted={@reverted}
        signer={@signer}
        chain_name={@chain_name}
        mismatch={@mismatch}
        check_event={@check_event}
        target={@target}
      />

      <p :if={@notice} class="token-swap__error" role="alert">{@notice}</p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :swapped, :map, required: true
  attr :stake_href, :string, default: nil
  attr :dismiss_event, :string, required: true
  attr :target, :any, default: nil

  def swap_done(assigns) do
    ~H"""
    <aside
      id={@id}
      class="token-swap__toast"
      role="status"
      phx-hook="Toast"
      data-variant={AutolaunchWeb.Motion.standard("toast")}
    >
      <div>
        <strong>Swapped</strong>
        <p>
          <AutolaunchWeb.TokenDisplay.written
            value={@swapped["paid_units"]}
            unit={@swapped["sell_symbol"]}
          /> for
          <AutolaunchWeb.TokenDisplay.written
            value={@swapped["received_units"]}
            unit={@swapped["buy_symbol"]}
          />
        </p>
        <.link :if={@stake_href} navigate={@stake_href} class="rg-button rg-button--secondary">Stake your tokens</.link>
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

  attr :next_step, :map, default: nil
  attr :steps, :list, required: true
  attr :reverted, :string, default: nil
  attr :signer, :string, default: nil, doc: "the review's signer; nil before there is a review"
  attr :chain_name, :string, default: nil
  attr :mismatch, :string, default: nil
  attr :check_event, :string, required: true
  attr :target, :any, default: nil

  @doc """
  The wallet button of a review panel, with the lines above it and "Check
  again" for a step the page stopped reading. The lines stay in the page and
  are only hidden, so one appearing never moves the button a person is
  pressing. The button has no `phx-click`: the `OnchainSteps` hook sends its
  step. It names the next step to send; once every step is sent it stays on
  the last one, and a press sends that step again.
  """
  def wallet_step(assigns) do
    assigns = assign(assigns, shown: pressable(assigns.next_step, assigns.steps))

    ~H"""
    <p class="token-swap__review-note" role="status" hidden={!@reverted}>{@reverted}</p>
    <p class="token-swap__review-from" hidden={!(@shown && @signer)}>
      Sending from <code>{RegentFormat.short_address(@signer)}</code> on {@chain_name}
    </p>
    <p class="onchain-note" role="status" hidden={!@mismatch}>{@mismatch}</p>
    <Regent.Primitives.button
      type="button"
      class="token-swap__submit token-swap__wallet-step"
      data-onchain-step={@shown && @shown.name}
      data-state={@shown && Map.get(@shown, :state)}
      hidden={!@shown}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["data-awaiting-wallet"])}
    >
      <span class="token-swap__wallet-step-label">{@shown && button_label(@shown, @next_step)}</span>
      <span class="token-swap__wallet-step-wait">
        <span class="token-swap__spinner" aria-hidden="true"></span> Confirm in wallet
      </span>
    </Regent.Primitives.button>
    <Regent.Primitives.button
      :for={step <- @steps}
      :if={step.state == :stalled}
      type="button"
      variant="secondary"
      class="token-swap__submit"
      phx-click={@check_event}
      phx-value-hash={step.entry.hash}
      phx-target={@target}
    >
      Check again
    </Regent.Primitives.button>
    """
  end

  @doc """
  The step a review panel's wallet button sends: the next one, or, once
  every step is sent, the last one again.
  """
  def pressable(nil, []), do: nil
  def pressable(nil, steps), do: List.last(steps)
  def pressable(next_step, _steps), do: next_step

  defp button_label(%{label: label}, nil), do: "#{label} again"
  defp button_label(%{label: label}, _next_step), do: label

  @doc "The note beside one step of a review panel."
  def step_note(%{state: :done}, _index, _count, _next), do: "Done"
  def step_note(%{state: :sent}, _index, _count, _next), do: "Waiting for the network"

  def step_note(%{state: :stalled}, _index, _count, _next),
    do: "Not confirmed yet. Check again, or look in your wallet activity"

  def step_note(%{state: :reverted}, _index, _count, _next), do: "Did not go through"

  def step_note(%{state: :other}, _index, _count, _next),
    do: "Sent a different transaction. Check your wallet activity"

  def step_note(%{name: name}, index, count, %{name: name}) when count > 1,
    do: "Step #{index} of #{count}"

  def step_note(_step, _index, _count, _next), do: nil

  defp output(:unread), do: "No quote right now"
  defp output(amount) when is_binary(amount), do: amount
  defp output(nil), do: "0"

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
