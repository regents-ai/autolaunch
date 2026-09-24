defmodule AutolaunchWeb.Components.AuctionHistory do
  @moduledoc """
  How an auction has gone so far, from its confirmed chain events: a timeline
  of the bidding window with each bid marked, the price everyone pays over
  time, the total bid over time, and the list of bids. Blocks are counted on
  the auction's own clock, the one its start and end blocks use.
  """
  use Phoenix.Component

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.{TokenDisplay, UsdValue}

  attr :id, :string, required: true
  attr :bids, :list, required: true, doc: "the auction's bids, oldest first"
  attr :points, :list, required: true, doc: "the auction's clearing prices, oldest first"
  attr :symbol, :string, required: true, doc: "the auction's currency"
  attr :token_symbol, :string, required: true
  attr :usd_rate, :any, required: true
  attr :block, :integer, required: true, doc: "the auction clock's current block"
  attr :start_block, :integer, required: true
  attr :end_block, :integer, required: true
  attr :chain, :atom, required: true, values: LaunchChain.chains()
  attr :test_chain, :boolean, required: true

  def auction_history(assigns) do
    now = assigns.block |> max(assigns.start_block) |> min(assigns.end_block)
    span = max(assigns.end_block - assigns.start_block, 1)

    assigns =
      assign(assigns,
        now: now,
        elapsed: min(div((now - assigns.start_block) * 100, span), 100),
        marks: Enum.map(assigns.bids, &share(&1.clock_block, assigns.start_block, span)),
        price_chart: price_chart(assigns.points, assigns.start_block, now),
        total_chart: total_chart(assigns.bids, assigns.points, assigns.start_block, now),
        newest: Enum.reverse(assigns.bids)
      )

    ~H"""
    <section id={@id} class="auction-history" aria-label="How this auction is going">
      <h2 class="autolaunch-micro">How this auction is going</h2>

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

      <div :if={@price_chart} class="auction-history__chart">
        <h3>Price per {@token_symbol}</h3>
        <p class="auction-history__figure">
          Now <TokenDisplay.price amount={@price_chart.last} unit={@symbol} />
          <UsdValue.usd amount={@price_chart.last} rate={@usd_rate} per="per token" /> · started at
          <TokenDisplay.price amount={@price_chart.first} unit={@symbol} />
        </p>
        <.plot chart={@price_chart} symbol={@symbol} />
        <p class="auction-history__note">
          Everyone who is buying pays this one price. It starts at the floor and
          rises only when bids ask for more tokens than are being released.
        </p>
      </div>

      <div :if={@total_chart} class="auction-history__chart">
        <h3>Bids placed and sold so far</h3>
        <ul class="auction-history__legend">
          <li class="auction-history__key auction-history__key--bids">
            Bids placed <TokenDisplay.price amount={@total_chart.last} unit={@symbol} />
          </li>
          <li :if={@total_chart.sold} class="auction-history__key auction-history__key--sold">
            Sold so far <TokenDisplay.price amount={@total_chart.sold} unit={@symbol} />
          </li>
        </ul>
        <.plot chart={@total_chart} symbol={@symbol} />
        <p class="auction-history__note">
          Bids placed is everything bidders have put in. Sold so far is the part
          already spent on tokens, which grows every block while bidding is open.
        </p>
      </div>

      <div :if={@bids != []} class="auction-history__bids">
        <h3>Bids</h3>
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
                <td title={bid.bidder}>{short_address(bid.bidder)}</td>
                <td>
                  <time datetime={DateTime.to_iso8601(bid.occurred_at)}>{ago(bid.occurred_at)}</time>
                </td>
                <td>
                  <TokenDisplay.price
                    amount={Decimal.to_string(bid.display_amount, :normal)}
                    unit={bid.display_symbol}
                  />
                </td>
                <td>
                  <TokenDisplay.price amount={Decimal.to_string(bid.amount, :normal)} unit={@symbol} />
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
    </section>
    """
  end

  # Where a block sits in the bidding window, as a percentage of its width.
  defp share(block, start, span), do: Float.round(min(max(block - start, 0) * 100 / span, 100), 2)

  attr :chart, :map, required: true
  attr :symbol, :string, required: true

  # Values run up the side from zero; blocks run along the bottom from the
  # opening to now.
  defp plot(assigns) do
    ~H"""
    <div class="auction-history__plot">
      <span class="auction-history__axis auction-history__axis--top">
        <TokenDisplay.price amount={@chart.top} unit={@symbol} />
      </span>
      <span class="auction-history__axis auction-history__axis--zero">0</span>
      <svg viewBox="0 0 600 120" preserveAspectRatio="none" aria-hidden="true">
        <path
          :for={{line, path} <- @chart.lines}
          class={"auction-history__line auction-history__line--#{line}"}
          d={path}
          vector-effect="non-scaling-stroke"
        />
      </svg>
      <span class="auction-history__axis auction-history__axis--start">
        Opened · block {grouped(@chart.start)}
      </span>
      <span class="auction-history__axis auction-history__axis--now">
        Now · block {grouped(@chart.now)}
      </span>
    </div>
    """
  end

  # The price carries each announced value forward to the next one and to now.
  defp price_chart([], _start, _now), do: nil

  defp price_chart(points, start, now) do
    steps = Enum.map(points, &{&1.clock_block, &1.clearing_price})
    {_block, first} = hd(steps)
    {_block, last} = List.last(steps)

    start
    |> chart(now, price: steps)
    |> Map.merge(%{first: plain(first), last: plain(last)})
  end

  # The running total bidders committed, one step per bid, beside what the
  # auction had sold at each price event.
  defp total_chart([], _points, _start, _now), do: nil

  defp total_chart(bids, points, start, now) do
    {steps, total} =
      Enum.map_reduce(bids, Decimal.new(0), fn bid, total ->
        total = Decimal.add(total, bid.amount)
        {{bid.clock_block, total}, total}
      end)

    sold = Enum.map(points, &{&1.clock_block, &1.sold})
    lines = [bids: [{start, Decimal.new(0)} | steps]]
    lines = if sold == [], do: lines, else: lines ++ [sold: [{start, Decimal.new(0)} | sold]]

    start
    |> chart(now, lines)
    |> Map.merge(%{
      last: plain(total),
      sold: sold != [] && sold |> List.last() |> elem(1) |> plain()
    })
  end

  # Step lines over the window from the opening to now, on one value axis from
  # zero to a little above the highest value, so a flat line stays in view.
  defp chart(start, now, lines) do
    top =
      lines
      |> Enum.flat_map(fn {_line, steps} -> Enum.map(steps, &elem(&1, 1)) end)
      |> Enum.max(Decimal)
      |> Decimal.mult(Decimal.new("1.15"))

    top = if Decimal.gt?(top, 0), do: top, else: Decimal.new(1)
    width = max(now - start, 1)
    x = fn block -> Float.round(min(max(block - start, 0), width) * 600 / width, 2) end

    y = fn value ->
      Float.round(120 - Decimal.to_float(Decimal.div(Decimal.mult(value, 120), top)), 2)
    end

    %{
      start: start,
      now: now,
      top: plain(top),
      lines: Enum.map(lines, fn {line, steps} -> {line, path(steps, x, y)} end)
    }
  end

  defp path(steps, x, y) do
    {segments, {_x, last_y}} =
      Enum.map_reduce(steps, nil, fn {block, value}, previous ->
        {px, py} = {x.(block), y.(value)}

        segment =
          case previous do
            nil -> "M#{px},#{py}"
            {_x, before} -> "L#{px},#{before} L#{px},#{py}"
          end

        {segment, {px, py}}
      end)

    Enum.join(segments, " ") <> " L600,#{last_y}"
  end

  defp plain(decimal), do: Decimal.to_string(decimal, :normal)

  defp closing(block, end_block, _chain, _test_chain) when block >= end_block,
    do: "Bidding ended at block #{grouped(end_block)}"

  defp closing(_block, end_block, _chain, true), do: "Ends at block #{grouped(end_block)}"

  defp closing(block, end_block, chain, false),
    do:
      "Ends at block #{grouped(end_block)}, in #{LaunchChain.time_estimate(chain, end_block - block)}"

  defp transaction_url(:base, hash), do: "https://basescan.org/tx/#{hash}"
  defp transaction_url(:robinhood, hash), do: "https://robinhoodchain.blockscout.com/tx/#{hash}"

  defp short_address(address),
    do: "#{String.slice(address, 0, 6)}…#{String.slice(address, -4, 4)}"

  defp explorer(:base), do: "Basescan"
  defp explorer(:robinhood), do: "Blockscout"

  defp ago(at) do
    seconds = DateTime.utc_now() |> DateTime.diff(at, :second) |> max(0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp grouped(block), do: block |> Integer.to_string() |> Amounts.grouped()
end
