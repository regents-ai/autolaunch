defmodule AutolaunchWeb.Components.AuctionPage do
  @moduledoc """
  The pieces both auction pages share around the chart: how the auction has
  gone so far, from its confirmed chain events (the list of bids, and a
  timeline of the bidding window with each bid marked), and the full-details
  window with its Details and How it works tabs. Blocks are counted on the
  auction's own clock, the one its start and end blocks use.

  Tabs switch in the browser alone, so a page update never moves the reader to
  another tab. The details window is a native popover: it opens from its
  button, and closes with its close button, Escape or a click outside it.
  """
  use Phoenix.Component

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.Components.BidPlaced
  alias AutolaunchWeb.TokenDisplay
  alias Phoenix.LiveView.JS

  attr :history, Phoenix.LiveView.AsyncResult, required: true

  @doc """
  Says when the bids could not be read: a failed first read shows no bids
  rather than none, and a failed re-read keeps the last ones marked as such.
  "Try again" sends `retry_history` to the page.
  """
  def history_note(assigns) do
    ~H"""
    <p :if={@history.failed} class="auction-history__failed" role="status">
      {if @history.ok?,
        do: "The bids could not be read again just now, so these are the last ones read.",
        else: "The bids could not be read just now."}
      <Regent.Primitives.button phx-click="retry_history" variant="secondary">
        Try again
      </Regent.Primitives.button>
    </p>
    """
  end

  attr :id, :string, required: true
  attr :bids, :list, required: true, doc: "the auction's bids, oldest first"
  attr :symbol, :string, required: true, doc: "the auction's currency"
  attr :block, :integer, required: true, doc: "the auction clock's current block"
  attr :start_block, :integer, required: true
  attr :end_block, :integer, required: true
  attr :chain, :atom, required: true, values: LaunchChain.chains()
  attr :test_chain, :boolean, required: true

  @doc "Every bid so far, newest first, and the bidding window's timeline."
  def auction_activity(assigns) do
    now = now(assigns)
    span = max(assigns.end_block - assigns.start_block, 1)

    assigns =
      assign(assigns,
        elapsed: min(div((now - assigns.start_block) * 100, span), 100),
        marks: Enum.map(assigns.bids, &share(&1.clock_block, assigns.start_block, span)),
        newest: Enum.reverse(assigns.bids),
        ended: assigns.block >= assigns.end_block
      )

    ~H"""
    <section id={@id} class="auction-history" aria-label="Bids and timeline">
      <.tabs id={"#{@id}-tabs"} label="Bids and timeline" class="auction-tabs--large">
        <:tab label="Activity">
          <div :if={@bids != []} class="auction-history__bids">
            <p class="auction-history__note">
              {bid_count(@bids)}{if !@ended, do: " so far"}, newest first.
            </p>
            <div class="auction-history__table">
              <table>
                <thead>
                  <tr>
                    <th scope="col">Wallet</th>
                    <th scope="col">When</th>
                    <th scope="col">Paid</th>
                    <th scope="col">Bid</th>
                    <th scope="col">Most per token</th>
                    <th scope="col">Block</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={bid <- @newest}>
                    <td title={bid.bidder}>{RegentFormat.short_address(bid.bidder)}</td>
                    <td>
                      <time datetime={DateTime.to_iso8601(bid.occurred_at)}>{RegentFormat.relative_time(
                        bid.occurred_at,
                        DateTime.utc_now()
                      )}</time>
                    </td>
                    <td>
                      <TokenDisplay.price
                        amount={Decimal.to_string(bid.display_amount, :normal)}
                        unit={bid.display_symbol}
                      />
                    </td>
                    <td>
                      <TokenDisplay.price
                        amount={Decimal.to_string(bid.amount, :normal)}
                        unit={@symbol}
                      />
                    </td>
                    <td>
                      <TokenDisplay.price
                        amount={Decimal.to_string(bid.max_price, :normal)}
                        unit={@symbol}
                      />
                    </td>
                    <td>
                      <a
                        :if={!@test_chain}
                        href={BidPlaced.transaction_url(@chain, bid.transaction_hash)}
                        target="_blank"
                        rel="noopener noreferrer"
                        aria-label={"View this bid's transaction on #{BidPlaced.explorer(@chain)}"}
                      >
                        {grouped(bid.clock_block)}
                      </a>
                      <span :if={@test_chain}>{grouped(bid.clock_block)}</span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
          <p :if={@bids == []} class="auction-history__note">No bids yet.</p>
        </:tab>
        <:tab label="Timeline">
          <div class="auction-history__timeline">
            <div
              class="auction-history__track"
              role="img"
              aria-label={"#{@elapsed}% of bidding time has passed; #{length(@bids)} bids so far"}
            >
              <span class="auction-history__elapsed" style={"width: #{@elapsed}%"}></span>
              <span
                :for={mark <- @marks}
                class="auction-history__mark"
                style={"left: #{mark}%"}
              ></span>
              <span class="auction-history__now" style={"left: #{@elapsed}%"}></span>
            </div>
            <div class="auction-history__ends">
              <span>Opened at block {grouped(@start_block)}</span>
              <span>{closing(@block, @end_block, @chain, @test_chain)}</span>
            </div>
            <p class="auction-history__note">
              {@elapsed}% of the bidding time has passed. Each mark is a bid;
              the line shows where bidding is now.
            </p>
          </div>
        </:tab>
      </.tabs>
    </section>
    """
  end

  # The auction's clock now, held inside its bidding window.
  defp now(assigns), do: assigns.block |> max(assigns.start_block) |> min(assigns.end_block)

  defp bid_count([_one]), do: "1 bid"
  defp bid_count(bids), do: "#{length(bids)} bids"

  # Where a block sits in the bidding window, as a percentage of its width.
  defp share(block, start, span), do: Float.round(min(max(block - start, 0) * 100 / span, 100), 2)

  defp closing(block, end_block, _chain, _test_chain) when block >= end_block,
    do: "Bidding ended at block #{grouped(end_block)}"

  defp closing(_block, end_block, _chain, true), do: "Ends at block #{grouped(end_block)}"

  defp closing(block, end_block, chain, false),
    do:
      "Ends at block #{grouped(end_block)}, in #{LaunchChain.time_estimate(chain, end_block - block)}"

  defp grouped(block), do: block |> Integer.to_string() |> Amounts.grouped()

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "what the tabs choose between, for screen readers"
  attr :class, :string, default: nil

  slot :tab, required: true do
    attr :label, :string, required: true
  end

  slot :aside, doc: "shown at the end of the tab row, such as a link"

  # Tabs over panels; the first tab is shown first. The panels share one space
  # as tall as the tallest, so choosing a tab never changes the height.
  defp tabs(assigns) do
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
      <div class="auction-tabs__panels">
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
      {AutolaunchWeb.Motion.panel("sheet")}
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
            Enter the most you want to spend, and a max FDV: the most the whole token supply
            may be worth while your bid keeps buying.
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
            When bidding ends, claim the tokens your bid bought, then withdraw the part it
            didn't spend. If the auction doesn't reach its minimum, withdraw your whole bid.
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
