defmodule AutolaunchWeb.Components.AuctionPage do
  @moduledoc """
  The pieces both auction pages share around the chart: the row of headline
  figures, tab groups, and the full-details window with its Details and How it
  works tabs.

  Tabs switch in the browser alone, so a page update never moves the reader to
  another tab. The details window is a native popover: it opens from its
  button, and closes with its close button, Escape or a click outside it.
  """
  use Phoenix.Component

  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Phoenix.LiveView.JS

  attr :record, :map, required: true, doc: "the auction, with `fdv` loaded"
  attr :minimum, :string, required: true, doc: "the minimum to graduate, in whole units"
  attr :usd_rate, :any, required: true
  attr :details, :string, required: true, doc: "the id of the full-details window"

  @doc """
  The auction's headline figures in one row, wrapping on narrow screens: the
  price now, what all its tokens are worth at that price, everything bid so
  far and the minimum, with the link to the full details.
  """
  def headline(assigns) do
    ~H"""
    <div class="auction-headline">
      <dl aria-label="Auction figures">
        <div class="auction-headline__stat">
          <dt>Price now</dt>
          <dd>
            <strong>
              <TokenDisplay.price
                amount={@record.current_clearing_price}
                unit={@record.quote_token_symbol}
              />
            </strong>
            <UsdValue.usd
              amount={@record.current_clearing_price}
              rate={@usd_rate}
              per="per token"
            />
          </dd>
        </div>
        <div class="auction-headline__stat">
          <dt>FDV</dt>
          <dd>
            <strong>{short(@record.fdv, @record.quote_token_symbol)}</strong>
            <UsdValue.usd amount={@record.fdv} rate={@usd_rate} />
          </dd>
        </div>
        <div class="auction-headline__stat">
          <dt>Bids placed</dt>
          <dd>
            <strong>{short(@record.bid_volume, @record.quote_token_symbol)}</strong>
            <UsdValue.usd amount={@record.bid_volume} rate={@usd_rate} />
          </dd>
        </div>
        <div class="auction-headline__stat">
          <dt>Minimum to graduate</dt>
          <dd>
            <strong>{short(Decimal.new(@minimum), @record.quote_token_symbol)}</strong>
            <UsdValue.usd amount={@minimum} rate={@usd_rate} />
          </dd>
        </div>
      </dl>
      <button type="button" class="auction-details-open" popovertarget={@details}>
        See full details <span aria-hidden="true">→</span>
      </button>
    </div>
    """
  end

  defp short(%Decimal{} = amount, symbol), do: "#{MarketCard.compact(amount)} #{symbol}"
  defp short(nil, _symbol), do: "—"

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the tabs choose between, for screen readers"
  attr :class, :string, default: nil

  slot :tab, required: true do
    attr :label, :string, required: true
  end

  slot :aside, doc: "shown at the end of the tab row, such as a link"

  @doc "Tabs over panels; the first tab is shown first."
  def tabs(assigns) do
    assigns = assign(assigns, :tabs, Enum.with_index(assigns.tab))

    ~H"""
    <div id={@id} class={["auction-tabs", @class]}>
      <div class="auction-tabs__bar">
        <div role="tablist" aria-label={@label} class="auction-tabs__list">
          <button
            :for={{tab, index} <- @tabs}
            type="button"
            role="tab"
            id={"#{@id}-tab-#{index}"}
            class="auction-tabs__tab"
            aria-controls={"#{@id}-panel-#{index}"}
            aria-selected={to_string(index == 0)}
            phx-click={chosen(@id, index, length(@tabs))}
          >
            {tab.label}
          </button>
        </div>
        {render_slot(@aside)}
      </div>
      <div
        :for={{tab, index} <- @tabs}
        role="tabpanel"
        id={"#{@id}-panel-#{index}"}
        class="auction-tabs__panel"
        aria-labelledby={"#{@id}-tab-#{index}"}
        hidden={index != 0}
      >
        {render_slot(tab)}
      </div>
    </div>
    """
  end

  defp chosen(id, choice, count) do
    Enum.reduce(0..(count - 1), %JS{}, fn
      ^choice, js ->
        js
        |> JS.set_attribute({"aria-selected", "true"}, to: "##{id}-tab-#{choice}")
        |> JS.remove_attribute("hidden", to: "##{id}-panel-#{choice}")

      other, js ->
        js
        |> JS.set_attribute({"aria-selected", "false"}, to: "##{id}-tab-#{other}")
        |> JS.set_attribute({"hidden", ""}, to: "##{id}-panel-#{other}")
    end)
  end

  attr :id, :string, required: true
  slot :inner_block, required: true, doc: "the auction's details"

  @doc "The full-details window: the auction's details, and how an auction works."
  def details_window(assigns) do
    ~H"""
    <div
      id={@id}
      popover
      class="auction-details-window"
      role="dialog"
      aria-modal="true"
      aria-label="Full auction details"
    >
      <.tabs id={"#{@id}-tabs"} label="Full auction details">
        <:tab label="Details">
          <div class="auction-details-window__details">{render_slot(@inner_block)}</div>
        </:tab>
        <:tab label="How it works">
          <.how_it_works />
        </:tab>
        <:aside>
          <button
            type="button"
            class="auction-details-window__close"
            popovertarget={@id}
            popovertargetaction="hide"
            aria-label="Close"
          >
            ×
          </button>
        </:aside>
      </.tabs>
    </div>
    """
  end

  defp how_it_works(assigns) do
    ~H"""
    <div class="auction-how">
      <p>
        Tokens are released a little at a time while bidding is open, and everyone
        buying at that moment pays the same price.
      </p>
      <ol class="auction-how__steps">
        <li>
          <h3>Choose your budget and the most you'll pay</h3>
          <p>
            Enter the total you want to spend. Bid at the current price, or set the most
            you'll pay per token.
          </p>
        </li>
        <li>
          <h3>Your bid buys as tokens are released</h3>
          <p>
            As bidding goes on, tokens go to the bids that pay the current price or more,
            and they all pay that one price. The price rises only when bids ask for more tokens than
            are being released. Your bid stops buying once the price passes the most you'll pay.
          </p>
        </li>
        <li>
          <h3>Claim your tokens and what you didn't spend</h3>
          <p>
            When bidding ends, claim the tokens your bid bought; the part it didn't spend
            comes back to you. If the auction doesn't reach its minimum, every bid comes
            back in full.
          </p>
        </li>
      </ol>
      <p class="auction-how__note">
        Outbid while bidding is still open? You keep what your bid bought. Once the
        auction has reached its minimum and recorded a price above your bid, you can
        get the rest back early.
      </p>
    </div>
    """
  end
end
