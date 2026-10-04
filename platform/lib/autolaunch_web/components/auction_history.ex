defmodule AutolaunchWeb.Components.AuctionHistory do
  @moduledoc """
  How an auction has gone so far, from its confirmed chain events: the list
  of bids, and a timeline of the bidding window with each bid marked. Blocks
  are counted on the auction's own clock, the one its start and end blocks use.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.AuctionPage, only: [tabs: 1]

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.TokenDisplay

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
                        href={transaction_url(@chain, bid.transaction_hash)}
                        target="_blank"
                        rel="noopener noreferrer"
                        aria-label={"View this bid's transaction on #{explorer(@chain)}"}
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

  defp transaction_url(:base, hash), do: "https://basescan.org/tx/#{hash}"
  defp transaction_url(:robinhood, hash), do: "https://robinhoodchain.blockscout.com/tx/#{hash}"

  defp explorer(:base), do: "Basescan"
  defp explorer(:robinhood), do: "Blockscout"

  defp grouped(block), do: block |> Integer.to_string() |> Amounts.grouped()
end
