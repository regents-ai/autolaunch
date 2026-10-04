defmodule AutolaunchWeb.Components.AuctionNext do
  @moduledoc """
  The pieces of the auction page (`/auctions/<TICKER>/<tail>`), all
  drawn from one chain reading (`Autolaunch.AuctionSnapshot`) and the
  auction's recorded prices:

    * `stage_rail/1` - where the auction is, from creation to its pool;
    * `figures/1` - the price now, the amount raised against the minimum, and
      a live countdown to the end of bidding;
    * `filmstrip/1` - the recorded prices over the bidding window with the
      release schedule under them, a replay of each recorded price, and the
      drafted maximum;
    * `ladder/1` - the prices bids are waiting at, how much is bidding at
      each, and how much more bidding it takes to reach it;
    * `receipt/1` and `check_bid/1` - one bid as the auction holds it.

  Prices are shown per million tokens, since one token costs a tiny fraction
  of the currency; the exact price per token stays beside them. Every figure
  says where it comes from: read from the chain at a block, worked out from
  the auction's state at a block, or an estimate.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.InfoTip

  alias Autolaunch.{AuctionSnapshot, BidActions, LaunchChain}
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.TokenDisplay
  alias Phoenix.LiveView.JS

  @million Decimal.new(1_000_000)
  @all_mps 10_000_000
  # The ladder shows this many prices above the price now; the rest are in its table.
  @rungs 8

  @steps [
    created: "Created",
    open: "Bidding open",
    ended: "Bidding ended",
    finishing: "Finishing",
    pool_ready: "Pool ready"
  ]

  attr :stage, :atom, required: true

  @doc "Where the auction is: each step done, current or still to come."
  def stage_rail(assigns) do
    assigns = assign(assigns, :steps, rail(assigns.stage))

    ~H"""
    <ol class="auction-next-rail" aria-label="Where this auction is">
      <li
        :for={{{_key, label, status}, index} <- Enum.with_index(@steps, 1)}
        class="auction-next-rail__step"
        data-status={status}
        aria-current={status == :current && "step"}
      >
        <span class="auction-next-rail__mark" aria-hidden="true">
          {mark(status, index)}
        </span>
        <span class="auction-next-rail__label">
          {label}<span class="visually-hidden">{status_words(status)}</span>
        </span>
      </li>
    </ol>
    """
  end

  defp rail(:failed) do
    done = @steps |> Enum.take(3) |> Enum.map(fn {key, label} -> {key, label, :done} end)
    done ++ [{:failed, "Minimum not reached", :failed}]
  end

  defp rail(stage) do
    current = Enum.find_index(@steps, fn {key, _label} -> key == stage end)

    @steps
    |> Enum.with_index()
    |> Enum.map(fn {{key, label}, index} ->
      {key, label, status(index, current, stage)}
    end)
  end

  defp status(index, current, :pool_ready) when index == current, do: :current
  defp status(index, current, _stage) when index < current, do: :done
  defp status(index, current, _stage) when index == current, do: :current
  defp status(_index, _current, _stage), do: :next

  defp mark(:done, _index), do: "✓"
  defp mark(:failed, _index), do: "!"
  defp mark(_status, index), do: index

  defp status_words(:done), do: ", done"
  defp status_words(:current), do: ", now"
  defp status_words(:failed), do: ", the auction ended here"
  defp status_words(:next), do: ", still to come"

  attr :snapshot, :map, required: true

  attr :minimum, :string,
    default: nil,
    doc: "a Revstake auction's minimum in whole currency; a Memestake auction shows none"

  attr :raised, :string,
    default: nil,
    doc: "the currency raised in whole currency, beside the minimum"

  attr :symbol, :string, required: true
  attr :token_symbol, :string, required: true
  attr :chain, :atom, required: true

  @doc """
  The price now per million tokens, on a Revstake auction the amount raised
  against the minimum, and a live countdown to the end of bidding. The countdown runs to a time worked
  out from the blocks left and the chain's block time, so it is an estimate;
  the end block it counts to is shown under it.
  """
  def figures(assigns) do
    assigns = assign(assigns, :ends_at, ends_at(assigns.snapshot, assigns.chain))

    ~H"""
    <dl class="auction-next-figures">
      <div class="auction-next-figure">
        <dt>
          <.info_tip
            id="auction-next-price-tip"
            text={
              if @ends_at,
                do:
                  "The auction starts at a floor price and goes up over time, with each block clearing at the highest price where demand exceeds supply.",
                else:
                  "The price the last block of bidding cleared at. Every winning bid pays this price for its tokens."
            }
          >
            {if @ends_at, do: "Price now", else: "Final price"} · per 1M {@token_symbol}
          </.info_tip>
        </dt>
        <dd>
          <strong class="auction-next-figure__value">
            <TokenDisplay.price amount={per_million(@snapshot.clearing)} unit={@symbol} />
          </strong>
          <span class="auction-next-figure__note">
            Exact: <TokenDisplay.price amount={@snapshot.clearing} unit={@symbol} /> per token.
            Read from the chain at block {grouped(@snapshot.block.number)}.
          </span>
        </dd>
      </div>
      <div :if={@minimum} class="auction-next-figure">
        <dt>Minimum to graduate</dt>
        <dd>
          <strong class="auction-next-figure__value">
            <TokenDisplay.price amount={@raised} unit={@symbol} />
          </strong>
          <span
            class="auction-next-figure__status"
            data-on={to_string(@snapshot.stage.facts.minimum_reached == true)}
          >
            {minimum_word(@snapshot.stage.facts.minimum_reached, @ends_at)}
          </span>
          <span class="auction-next-figure__note">
            Raised of the <TokenDisplay.price amount={@minimum} unit={@symbol} />
            minimum. {if @ends_at, do: "Reaching it does not end bidding."}
          </span>
        </dd>
      </div>
      <div class="auction-next-figure">
        <dt>{if @ends_at, do: "Bidding ends", else: "Bidding ended"}</dt>
        <dd>
          <strong
            :if={@ends_at}
            id="auction-next-countdown"
            class="auction-next-figure__value"
            phx-hook=".Countdown"
            phx-update="ignore"
            data-ends-at={@ends_at}
          >
            {countdown(@ends_at - System.os_time(:millisecond))}
          </strong>
          <strong :if={!@ends_at} class="auction-next-figure__value">Ended</strong>
          <span class="auction-next-figure__block">Block {grouped(@snapshot.blocks.end)}</span>
          <span class="auction-next-figure__note">{ending(@snapshot)}</span>
        </dd>
      </div>
    </dl>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
      // Counts down to the end time the server worked out, in days, hours and
      // minutes, written the same way as the server's first render.
      const pad = (value) => String(value).padStart(2, "0")

      const words = (left) => {
        if (left <= 0) return "Ending now"
        const minutes = Math.floor(left / 60000)
        if (minutes < 1) return "Under 1m"
        const days = Math.floor(minutes / 1440)
        const hours = Math.floor((minutes % 1440) / 60)
        const rest = minutes % 60
        if (days > 0) return `${days}d ${pad(hours)}h ${pad(rest)}m`
        if (hours > 0) return `${hours}h ${pad(rest)}m`
        return `${rest}m`
      }

      export default {
        mounted() {
          this.tick()
          this.timer = setInterval(() => this.tick(), 1000)
        },
        destroyed() {
          clearInterval(this.timer)
        },
        tick() {
          const text = words(Number(this.el.dataset.endsAt) - Date.now())
          if (this.el.textContent !== text) this.el.textContent = text
        }
      }
    </script>
    """
  end

  defp minimum_word(true, _ends_at), do: "Passed"
  defp minimum_word(_reached, nil), do: "Not reached"
  defp minimum_word(_reached, _ends_at), do: "Not yet"

  defp ends_at(%{clock: clock, blocks: %{end: finish}}, _chain) when clock >= finish, do: nil

  defp ends_at(%{clock: clock, blocks: %{end: finish}}, chain),
    do: System.os_time(:millisecond) + round(LaunchChain.seconds(chain, finish - clock) * 1000)

  defp countdown(left) when left <= 0, do: "Ending now"

  defp countdown(left) do
    minutes = div(left, 60_000)
    {days, hours, rest} = {div(minutes, 1440), div(rem(minutes, 1440), 60), rem(minutes, 60)}

    cond do
      minutes < 1 -> "Under 1m"
      days > 0 -> "#{days}d #{pad(hours)}h #{pad(rest)}m"
      hours > 0 -> "#{hours}h #{pad(rest)}m"
      true -> "#{rest}m"
    end
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp ending(%{clock: clock, blocks: %{end: finish}}) when clock >= finish,
    do: "The auction's clock is at block #{grouped(clock)}."

  defp ending(%{clock: clock, blocks: %{end: finish}}),
    do: "#{grouped(finish - clock)} blocks away. The time is estimated from block times."

  attr :id, :string, required: true

  @doc "How to bid in a continuous clearing auction, beside the bid form."
  def how_to_bid(assigns) do
    ~H"""
    <section id={@id} class="auction-next-card auction-next-howto" aria-labelledby={"#{@id}-title"}>
      <header class="auction-next-card__head">
        <h2 id={"#{@id}-title"}>How bidding works</h2>
      </header>
      <ul class="auction-next-howto__list">
        <li>You set a total budget and the max price you would pay for a token.</li>
        <li>Your budget is spread across all remaining blocks and spent over time, like a TWAP.</li>
        <li>
          Each block where the price is below your max price, part of your budget buys tokens.
          Once the price passes your max price, the rest stops buying.
        </li>
      </ul>
      <p class="auction-next-howto__advice">
        <strong>Bid early with your real max budget and your real max price.</strong>
        Your max price means you never buy a single token above what you are willing to pay, and
        waiting only gets you a worse average price. Everyone buys at the same rates, with no
        advantage for advanced users or MEV bots.
      </p>
      <.link navigate="/how-it-works#how-it-works-auction" class="auction-next-link">
        How the auction works
      </.link>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :snapshot, :map, required: true
  attr :points, :list, required: true, doc: "the auction's recorded prices, oldest first"
  attr :draft, :string, default: nil, doc: "the maximum price per token being drafted"
  attr :at, :integer, default: nil, doc: "the recorded price being replayed; nil for the latest"
  attr :symbol, :string, required: true
  attr :token_symbol, :string, required: true

  @doc """
  The recorded prices across the whole bidding window, with nothing drawn past
  now, the release schedule under them, and the drafted maximum as a dashed
  line. The slider replays the recorded prices one at a time, saying what the
  auction had recorded by then; it sends `scrub` with `checkpoint` and
  `scrub_now` to the page.
  """
  def filmstrip(assigns) do
    assigns =
      assign(assigns,
        film: film(assigns),
        ended: assigns.snapshot.clock >= assigns.snapshot.blocks.end
      )

    ~H"""
    <section id={@id} class="auction-next-card auction-next-film" aria-labelledby={"#{@id}-title"}>
      <header class="auction-next-film__head">
        <h2 id={"#{@id}-title"}>Token Bid Price</h2>
        <p class="auction-next-film__subtitle">Price per 1M {@token_symbol}</p>
      </header>
      <p class="auction-next-lead">The solid line is the price each block recorded.</p>
      <ul class="auction-next-film__tips">
        <li>
          The line only steps up when there is enough demand to buy the rest of the auction at a
          higher price. While it stays flat, every bid is still buying at that price.
        </li>
        <li :if={!@ended}>
          Type a max price in the bid form to see it here as a dashed line. Each block the price
          stays below it, part of your budget buys tokens; once the price passes it, the rest of
          your budget stops buying.
        </li>
        <li :if={!@ended}>
          Your budget is spread over the blocks left, so bidding earlier buys over more blocks.
          Waiting only gets you a worse average price.
        </li>
        <li>
          The bars underneath show how much of the supply each stage of the schedule releases.
        </li>
      </ul>
      <div class="auction-next-film__plot">
        <span class="auction-next-film__axis auction-next-film__axis--top">
          <TokenDisplay.price amount={per_million(@film.top)} unit={@symbol} />
        </span>
        <span class="auction-next-film__axis auction-next-film__axis--zero">0</span>
        <div class="auction-next-film__canvas">
          <svg
            viewBox="0 0 600 200"
            preserveAspectRatio="none"
            role="img"
            aria-labelledby={"#{@id}-summary"}
          >
            <rect
              class="auction-next-film__future"
              x={@film.now_x}
              y="0"
              width={600 - @film.now_x}
              height="200"
            />
            <path :if={@film.area} class="auction-next-film__area" d={@film.area} />
            <path
              :if={@film.line}
              class="auction-next-film__price"
              d={@film.line}
              vector-effect="non-scaling-stroke"
            />
            <line
              :if={@film.draft_y}
              class="auction-next-film__draft"
              x1="0"
              x2="600"
              y1={@film.draft_y}
              y2={@film.draft_y}
              vector-effect="non-scaling-stroke"
            />
            <line
              class="auction-next-film__now"
              x1={@film.now_x}
              x2={@film.now_x}
              y1="0"
              y2="200"
              vector-effect="non-scaling-stroke"
            />
            <line
              :if={@film.scrub}
              class="auction-next-film__scrub"
              x1={@film.scrub.x}
              x2={@film.scrub.x}
              y1="0"
              y2="200"
              vector-effect="non-scaling-stroke"
            />
          </svg>
          <span
            :if={@film.scrub}
            class="auction-next-film__dot"
            style={"left: #{@film.scrub.x / 6}%; top: #{@film.scrub.y / 2}%"}
            aria-hidden="true"
          ></span>
        </div>
      </div>
      <p class="auction-next-film__band-label">
        <.info_tip
          id={"#{@id}-band-tip"}
          text="Every CCA bid is split across all blocks for the remaining auction, in step with how much of the supply each block releases."
        >
          Supply released per block, by schedule stage
        </.info_tip>
      </p>
      <svg
        class="auction-next-film__band"
        viewBox="0 0 600 48"
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <rect
          :for={bar <- @film.bars}
          class={"auction-next-film__bar auction-next-film__bar--#{bar.kind}"}
          x={bar.x}
          y={48 - bar.h}
          width={bar.w}
          height={bar.h}
        />
      </svg>
      <p :for={lump <- @film.lumps} class="auction-next-source">
        Block {grouped(lump.block)} releases {lump.share} of the supply at once.
      </p>
      <div class="auction-next-film__ends">
        <span>Opened · block {grouped(@snapshot.blocks.start)}</span>
        <span>{if @ended, do: "Ended", else: "Ends"} · block {grouped(@snapshot.blocks.end)}</span>
      </div>
      <ul class="auction-next-legend" role="list">
        <li class="auction-next-legend__price">Recorded price</li>
        <li :if={@film.draft_y} class="auction-next-legend__draft">Your draft maximum</li>
        <li
          :if={!@film.draft_y && !@ended}
          class="auction-next-legend__draft auction-next-legend--off"
        >
          Your draft maximum (type one in the bid form)
        </li>
        <li class="auction-next-legend__released">Released so far</li>
        <li :if={!@ended} class="auction-next-legend__upcoming">Still to release</li>
      </ul>

      <form
        :if={@film.count > 0}
        id={"#{@id}-scrub"}
        class="auction-next-film__scrubber"
        phx-change="scrub"
        onsubmit="return false"
      >
        <label for={"#{@id}-checkpoint"}>
          Replay the recorded prices <span>Price {@film.index + 1} of {@film.count}</span>
        </label>
        <input
          id={"#{@id}-checkpoint"}
          type="range"
          name="checkpoint"
          min="0"
          max={@film.count - 1}
          step="1"
          value={@film.index}
          aria-valuetext={"Price #{@film.index + 1} of #{@film.count}, block #{grouped(@film.scrub.block)}"}
        />
      </form>
      <p id={"#{@id}-summary"} class="auction-next-film__reading" aria-live="polite">
        {summary(@film, @symbol, @token_symbol)}
      </p>
      <p :if={@draft && @film.draft_note} class="auction-next-note" data-tone={@film.draft_note.tone}>
        {@film.draft_note.text}
      </p>
      <button
        :if={@at}
        type="button"
        class="auction-next-link"
        phx-click="scrub_now"
      >
        Back to the latest price
      </button>
      <p class="auction-next-source">
        Prices: each one the auction recorded, from its events on the chain. Schedule: read
        from the auction at block {grouped(@snapshot.block.number)}. No future price is drawn.
      </p>

      <Regent.Primitives.disclosure id={"#{@id}-table"} summary="The chart as a table">
        <table class="auction-next-table">
          <caption>Recorded prices, per 1M {@token_symbol}</caption>
          <thead>
            <tr>
              <th scope="col">Block</th>
              <th scope="col">Price per 1M</th>
              <th scope="col">Sold so far</th>
              <th scope="col">Supply released by then</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={point <- @points}>
              <td>{grouped(point.clock_block)}</td>
              <td>
                <TokenDisplay.price amount={per_million(point.clearing_price)} unit={@symbol} />
              </td>
              <td><TokenDisplay.price amount={plain(point.sold)} unit={@symbol} /></td>
              <td>{released_percent(@snapshot.schedule, point.clock_block)}</td>
            </tr>
          </tbody>
        </table>
        <table class="auction-next-table">
          <caption>Release schedule</caption>
          <thead>
            <tr>
              <th scope="col">Blocks</th>
              <th scope="col">Share of supply per block</th>
              <th scope="col">Share of supply in this stage</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={step <- @snapshot.schedule}>
              <td>{grouped(step.from)} to {grouped(step.to)}</td>
              <td>{share(step.mps)}</td>
              <td>{share(step.mps * (step.to - step.from))}</td>
            </tr>
          </tbody>
        </table>
      </Regent.Primitives.disclosure>
    </section>
    """
  end

  # Everything the chart draws, on a 600 by 200 box for prices and 600 by 48
  # for the schedule, over the whole bidding window.
  defp film(%{snapshot: snapshot, points: points, draft: draft, at: at}) do
    %{start: start, end: finish} = snapshot.blocks
    span = max(finish - start, 1)
    x = fn block -> Float.round(min(max(block - start, 0), span) * 600 / span, 2) end
    now = snapshot.clock |> max(start) |> min(finish)
    steps = Enum.map(points, &{&1.clock_block, &1.clearing_price})
    draft = draft_decimal(draft)

    top =
      [exact(snapshot.clearing) | Enum.map(steps, &elem(&1, 1))]
      |> then(&if(draft, do: [draft | &1], else: &1))
      |> Enum.max(Decimal)
      |> Decimal.mult(Decimal.new("1.15"))
      |> then(&if(Decimal.gt?(&1, 0), do: &1, else: Decimal.new(1)))

    y = fn value ->
      Float.round(200 - Decimal.to_float(Decimal.div(Decimal.mult(value, 200), top)), 2)
    end

    tallest = tallest_rate(snapshot.schedule)
    count = length(points)
    index = if at, do: min(at, count - 1), else: count - 1

    %{
      top: plain(top),
      now_x: x.(now),
      line: price_line(steps, x, y, now),
      area: price_area(steps, x, y, now),
      draft_y: draft && y.(draft),
      draft_note: draft && draft_note(draft, snapshot),
      bars: bars(snapshot.schedule, x, snapshot.clock, tallest),
      lumps: lumps(snapshot.schedule, tallest),
      count: count,
      index: index,
      scrub: scrub(points, index, x, y, snapshot.schedule)
    }
  end

  defp price_line([], _x, _y, _now), do: nil

  defp price_line(steps, x, y, now) do
    {segments, last_y} =
      Enum.map_reduce(steps, nil, fn {block, price}, previous ->
        {px, py} = {x.(block), y.(price)}

        segment =
          case previous do
            nil -> "M#{px},#{py}"
            before -> "L#{px},#{before} L#{px},#{py}"
          end

        {segment, py}
      end)

    Enum.join(segments, " ") <> " L#{x.(now)},#{last_y}"
  end

  defp price_area([], _x, _y, _now), do: nil

  defp price_area([{first, _price} | _rest] = steps, x, y, now),
    do: price_line(steps, x, y, now) <> " L#{x.(now)},200 L#{x.(first)},200 Z"

  # The bars are scaled to the fastest stage lasting more than one block. A
  # one-block stage can release a large share at once; it is drawn full height
  # and named beneath the bars, so it does not flatten every other stage.
  defp tallest_rate(schedule) do
    schedule
    |> Enum.reject(&(&1.to - &1.from == 1))
    |> Enum.map(& &1.mps)
    |> Enum.max(fn -> 1 end)
    |> max(1)
  end

  defp lumps(schedule, tallest) do
    for %{from: from, to: to, mps: mps} <- schedule,
        to - from == 1,
        mps > tallest,
        do: %{block: from, share: share(mps)}
  end

  # Each schedule stage as a bar as tall as its rate per block, split where
  # the auction's clock is now into what it has released and what it has not.
  defp bars(schedule, x, clock, tallest) do
    Enum.flat_map(schedule, fn %{from: from, to: to, mps: mps} ->
      h = Float.round(min(max(mps * 44 / tallest, if(mps > 0, do: 2.0, else: 0.0)), 44.0), 2)

      [
        {:released, from, min(to, clock)},
        {:upcoming, max(from, clock), to}
      ]
      |> Enum.filter(fn {_kind, a, b} -> b > a end)
      |> Enum.map(fn {kind, a, b} ->
        w = max(Float.round(x.(b) - x.(a) - 0.6, 2), 2.0)
        %{kind: kind, x: min(x.(a), 600 - w), w: w, h: h}
      end)
    end)
  end

  defp scrub([], _index, _x, _y, _schedule), do: nil

  defp scrub(points, index, x, y, schedule) do
    point = Enum.at(points, index)

    %{
      block: point.clock_block,
      x: x.(point.clock_block),
      y: y.(point.clearing_price),
      price: plain(point.clearing_price),
      sold: plain(point.sold),
      released: released_percent(schedule, point.clock_block)
    }
  end

  defp summary(%{scrub: nil}, _symbol, _token_symbol),
    do: "No price recorded yet. The first one appears once the auction records a bid."

  defp summary(%{scrub: scrub}, symbol, token_symbol),
    do:
      "At block #{grouped(scrub.block)} the price was #{TokenDisplay.short(per_million(scrub.price))} #{symbol} per 1M #{token_symbol}, " <>
        "#{TokenDisplay.short(scrub.sold)} #{symbol} had been spent on tokens, and the schedule had released #{scrub.released} of the supply."

  defp draft_note(draft, %{clearing: clearing}) do
    if Decimal.gt?(draft, exact(clearing)),
      do: %{
        tone: "above",
        text:
          "Your draft maximum is above the price now. What it buys still depends on how bidding goes from here."
      },
      else: %{
        tone: "below",
        text:
          "Your draft maximum is at or below the price now, so a bid at it would not buy tokens."
      }
  end

  attr :id, :string, required: true
  attr :snapshot, :map, required: true
  attr :draft, :string, default: nil, doc: "the maximum price per token being drafted"
  attr :symbol, :string, required: true
  attr :token_symbol, :string, required: true
  attr :bid_form, :string, required: true, doc: "the bid form's DOM id, for \"Use this price\""

  @doc """
  The prices bids are waiting at above the price now, lowest nearest the
  price: the bidding at each, and the further bidding it takes before the
  price reaches it, worked out as the auction's own lens does. The drafted
  maximum sits among them with its own figure.
  """
  def ladder(assigns) do
    assigns = assign(assigns, :view, ladder_view(assigns))

    ~H"""
    <section id={@id} class="auction-next-card auction-next-ladder" aria-labelledby={"#{@id}-title"}>
      <header class="auction-next-card__head">
        <h2 id={"#{@id}-title"}>Where bids are waiting</h2>
        <span class="auction-next-tag">Price per 1M {@token_symbol}</span>
      </header>
      <p class="auction-next-lead">
        Each row is a maximum price bids are waiting at. "More bidding needed" is how much
        more would have to be bid before the price reaches that row. It is a picture of now,
        not a forecast.
      </p>
      <p class="auction-next-lead">
        The price stays at the floor until there is enough demand to buy out the entire auction
        at the floor or higher. At that point every bid above the floor pushes the clearing
        price up, again spread across all remaining blocks. Simple supply and demand.
      </p>
      <div :if={@snapshot.price_to_beat} class="auction-next-ladder__beat">
        <span>
          To start buying now, bid at least
          <strong><TokenDisplay.price amount={per_million(@snapshot.price_to_beat)} unit={@symbol} /></strong>
          per 1M
        </span>
        <Regent.Primitives.button
          type="button"
          variant="secondary"
          phx-click={
            "use_price"
            |> JS.push(value: %{price: @snapshot.price_to_beat}, target: "##{@bid_form}")
            |> JS.focus(to: "##{@bid_form}-max-fdv")
          }
        >
          Use this price
        </Regent.Primitives.button>
      </div>
      <ol class="auction-next-ladder__rows" role="list">
        <li :if={@view.hidden > 0} class="auction-next-ladder__more">
          {@view.hidden} higher {if @view.hidden == 1, do: "price", else: "prices"} in the table below
        </li>
        <li class="auction-next-ladder__head" aria-hidden="true">
          <span>Price per 1M</span><span>Bidding here</span><span>More bidding needed</span>
        </li>
        <li
          :for={row <- @view.rows}
          class="auction-next-ladder__row"
          data-kind={row.kind}
        >
          <span class="auction-next-ladder__price">
            <TokenDisplay.price amount={per_million(row.price)} unit={@symbol} />
            <small :if={row.kind == :draft}>Your draft maximum</small>
          </span>
          <span class="auction-next-ladder__bidding">
            <span class="auction-next-ladder__bar" aria-hidden="true">
              <span style={"width: #{row.width}%"}></span>
            </span>
            <span :if={row.bidding}><TokenDisplay.price amount={row.bidding} unit={@symbol} /></span>
            <span :if={!row.bidding}>—</span>
          </span>
          <span class="auction-next-ladder__needed">
            <small class="auction-next-ladder__needed-label">More bidding needed</small>
            <TokenDisplay.price amount={row.needed} unit={@symbol} fallback="Reached" />
          </span>
        </li>
        <li class="auction-next-ladder__now">
          <span>Price now</span>
          <span><TokenDisplay.price amount={per_million(@snapshot.clearing)} unit={@symbol} /></span>
        </li>
      </ol>
      <p :if={@view.rows == []} class="auction-next-note">
        No bids are waiting above the price now.
      </p>
      <p :if={@view.draft_below} class="auction-next-note" data-tone="below">
        Your draft maximum is at or below the price now, so it is not on the ladder.
      </p>
      <p :if={!@snapshot.ladder.complete?} class="auction-next-note">
        Only the lowest 1,000 prices were read; higher ones are not shown.
      </p>
      <p class="auction-next-source">
        Worked out from the auction's state as it last recorded it, at block {grouped(
          @snapshot.ladder.state.checkpoint_block
        )}. Bids placed since then count once the
        auction records again.
      </p>
      <Regent.Primitives.disclosure
        :if={@snapshot.ladder.rungs != []}
        id={"#{@id}-table"}
        summary={"All #{length(@snapshot.ladder.rungs)} prices as a table"}
      >
        <table class="auction-next-table">
          <caption>Prices bids are waiting at, lowest first</caption>
          <thead>
            <tr>
              <th scope="col">Price per 1M</th>
              <th scope="col">Exact price per token</th>
              <th scope="col">Bidding here</th>
              <th scope="col">More bidding needed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rung <- @snapshot.ladder.rungs}>
              <td><TokenDisplay.price amount={per_million(rung.price)} unit={@symbol} /></td>
              <td class="autolaunch-exact-value">{rung.price}</td>
              <td><TokenDisplay.price amount={rung.bidding} unit={@symbol} /></td>
              <td><TokenDisplay.price amount={rung.needed} unit={@symbol} fallback="Reached" /></td>
            </tr>
          </tbody>
        </table>
      </Regent.Primitives.disclosure>
    </section>
    """
  end

  defp ladder_view(%{snapshot: snapshot, draft: draft}) do
    rungs = snapshot.ladder.rungs
    shown = Enum.take(rungs, @rungs)
    draft_q96 = draft_q96(draft, snapshot.decimals)
    above? = is_integer(draft_q96) and draft_q96 > snapshot.ladder.state.clearing_q96

    rows =
      Enum.map(
        shown,
        &%{
          kind: :rung,
          price_q96: &1.price_q96,
          price: &1.price,
          bidding: &1.bidding,
          needed: zero_nil(&1.needed)
        }
      )

    rows =
      if above?,
        do: [
          %{
            kind: :draft,
            price_q96: draft_q96,
            price: draft,
            bidding: nil,
            needed: zero_nil(AuctionSnapshot.needed_at(draft_q96, snapshot))
          }
          | rows
        ],
        else: rows

    widest =
      rows
      |> Enum.map(&(&1.bidding && exact(&1.bidding)))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(Decimal, fn -> Decimal.new(0) end)

    %{
      hidden: length(rungs) - length(shown),
      draft_below: is_integer(draft_q96) and not above?,
      rows:
        rows
        |> Enum.sort_by(& &1.price_q96, :desc)
        |> Enum.map(&Map.put(&1, :width, width(&1.bidding, widest)))
    }
  end

  defp width(nil, _widest), do: 0

  defp width(amount, widest) do
    if Decimal.gt?(widest, 0),
      do:
        amount
        |> exact()
        |> Decimal.mult(100)
        |> Decimal.div(widest)
        |> Decimal.round(1)
        |> Decimal.to_float(),
      else: 0
  end

  defp zero_nil(nil), do: nil
  defp zero_nil(amount), do: if(Decimal.eq?(exact(amount), 0), do: nil, else: amount)

  attr :id, :string, required: true
  attr :receipt, :map, required: true, doc: "`Autolaunch.BidReceipt`"
  attr :wallet, :string, default: nil, doc: "the signed-in wallet, if any"
  attr :symbol, :string, required: true
  attr :token_symbol, :string, required: true
  attr :claim_block, :integer, required: true

  @doc """
  One bid as the auction holds it: what went in, how much the auction has
  used and what is left, the tokens so far, and who owns it. Unspent money is
  never called withdrawable: it comes back when the bid is withdrawn.
  """
  def receipt(assigns) do
    assigns = assign(assigns, :used_share, used_share(assigns.receipt))

    ~H"""
    <article id={@id} class="auction-next-receipt" aria-label={"Bid #{@receipt.id}"}>
      <header class="auction-next-receipt__head">
        <strong>
          <TokenDisplay.price amount={@receipt.deposited} unit={@symbol} /> put in
        </strong>
        <span class="auction-next-receipt__id">Bid #{@receipt.id}</span>
      </header>

      <div :if={@receipt.state == :buying}>
        <div
          class="auction-next-receipt__bar"
          role="img"
          aria-label={"#{@used_share}% used on tokens, the rest unspent"}
        >
          <span style={"width: #{@used_share}%"}></span>
        </div>
        <dl class="auction-next-receipt__split">
          <div>
            <dt>Used on tokens so far</dt>
            <dd><TokenDisplay.price amount={@receipt.used} unit={@symbol} /></dd>
          </div>
          <div>
            <dt>
              <.info_tip
                id={"#{@id}-unspent-tip"}
                text="Each block where the clearing price is lower than your max price, you receive tokens for a portion of your budget. If your max price is exceeded, the rest of your budget stops buying."
              >
                Unspent
              </.info_tip>
            </dt>
            <dd>
              <TokenDisplay.price amount={@receipt.unspent} unit={@symbol} />
              <small>Not automatically withdrawable</small>
            </dd>
          </div>
        </dl>
      </div>
      <p :if={@receipt.state == :stopped} class="auction-next-note" data-tone="below">
        This bid's maximum is at or below the price now, so it has stopped buying. How much of it
        was used is settled when it is withdrawn.
      </p>
      <p :if={@receipt.state == :withdrawn} class="auction-next-note">
        This bid was withdrawn at block {grouped(@receipt.exited_block)}.
      </p>

      <dl class="auction-next-receipt__rows">
        <div :if={@receipt.state == :buying}>
          <dt>Tokens so far</dt>
          <dd><TokenDisplay.tokens amount={@receipt.tokens} unit={@token_symbol} /></dd>
        </div>
        <div>
          <dt>Maximum price per 1M</dt>
          <dd><TokenDisplay.price amount={per_million(@receipt.max_price)} unit={@symbol} /></dd>
        </div>
        <div>
          <dt>Standing</dt>
          <dd>{standing(@receipt.standing)}</dd>
        </div>
        <div>
          <dt>Owner</dt>
          <dd>
            <span title={@receipt.owner}>{RegentFormat.short_address(@receipt.owner)}</span>
            <small>{owner_note(@receipt.owner, @wallet)}</small>
          </dd>
        </div>
        <div>
          <dt>Claiming tokens</dt>
          <dd>Once the pool is ready, from block {grouped(@claim_block)}</dd>
        </div>
        <div>
          <dt>Getting unspent money back</dt>
          <dd>
            When the bid is withdrawn: after bidding ends, or earlier once the price passes
            this bid's maximum.
          </dd>
        </div>
      </dl>
      <p class="auction-next-source">Read from the chain at block {grouped(@receipt.block)}.</p>
    </article>
    """
  end

  defp used_share(%{state: :buying, used: used, deposited: deposited}) do
    deposited = exact(deposited)

    if Decimal.gt?(deposited, 0),
      do:
        used
        |> exact()
        |> Decimal.mult(100)
        |> Decimal.div(deposited)
        |> Decimal.round(1)
        |> Decimal.to_float(),
      else: 0
  end

  defp used_share(_receipt), do: 0

  defp standing(:in), do: "Above the price: buying at the price every block"
  defp standing(:sharing), do: "At the price: shares what higher bids leave"
  defp standing(:outbid), do: "Below the price: no longer buying"

  defp owner_note(_owner, nil), do: "Only this wallet can claim or withdraw this bid."

  defp owner_note(owner, wallet) do
    if String.downcase(owner) == String.downcase(wallet),
      do: "Your signed-in wallet.",
      else: "Not your signed-in wallet: only this wallet can claim or withdraw this bid."
  end

  attr :id, :string, required: true
  attr :checked, :any, required: true, doc: "an AsyncResult of the bid checked, or nil"
  attr :number, :string, default: "", doc: "the bid number as typed"
  attr :symbol, :string, required: true
  attr :token_symbol, :string, required: true
  attr :wallet, :string, default: nil
  attr :claim_block, :integer, required: true

  @doc """
  Look up any bid on this auction by its number, which the auction gives
  each bid in order from 0. Sends `check_bid` with `bid` to the page.
  """
  def check_bid(assigns) do
    ~H"""
    <section id={@id} class="auction-next-card" aria-labelledby={"#{@id}-title"}>
      <header class="auction-next-card__head">
        <h2 id={"#{@id}-title"}>Check a bid</h2>
      </header>
      <p class="auction-next-lead">
        A bid is a total budget with a max price, not a fixed number of tokens. Enter a bid's
        number to see how much of it the auction has used and what is left.
      </p>
      <form id={"#{@id}-form"} class="auction-next-check" phx-submit="check_bid">
        <label for={"#{@id}-number"}>Bid number</label>
        <input
          id={"#{@id}-number"}
          type="number"
          name="bid"
          min="0"
          step="1"
          inputmode="numeric"
          value={@number}
          required
        />
        <Regent.Primitives.button type="submit" variant="secondary">Check</Regent.Primitives.button>
      </form>
      <p :if={@checked && @checked.loading} class="auction-next-note" role="status">
        Reading the bid…
      </p>
      <p :if={@checked && @checked.failed} class="auction-next-note" role="status">
        {check_failed(@checked.failed, @number)}
      </p>
      <.receipt
        :if={@checked && @checked.ok? && @checked.result}
        id={"#{@id}-receipt"}
        receipt={@checked.result}
        wallet={@wallet}
        symbol={@symbol}
        token_symbol={@token_symbol}
        claim_block={@claim_block}
      />
    </section>
    """
  end

  defp check_failed({:error, :bid_not_found}, number),
    do: "This auction has no bid #{number} yet."

  defp check_failed({:error, :invalid_bid_number}, _number),
    do: "Enter a whole number, such as 0."

  defp check_failed(_reason, _number), do: "This bid could not be read just now. Try again."

  @doc "A price per token as a price per million tokens."
  @spec per_million(String.t() | Decimal.t() | nil) :: String.t() | nil
  def per_million(nil), do: nil

  def per_million(price),
    do: price |> exact() |> Decimal.mult(@million) |> Decimal.normalize() |> plain()

  defp draft_decimal(nil), do: nil

  defp draft_decimal(draft) do
    case Decimal.parse(draft) do
      {decimal, ""} -> if Decimal.gt?(decimal, 0), do: decimal
      _unreadable -> nil
    end
  end

  defp draft_q96(nil, _decimals), do: nil

  defp draft_q96(draft, decimals) do
    case BidActions.price_q96(draft, decimals) do
      {:ok, q96} -> q96
      {:error, _unreadable} -> nil
    end
  end

  defp released_percent(schedule, block),
    do: share(AuctionSnapshot.released_mps(schedule, block))

  # A part of the supply, counted as the schedule counts it (ten million in all).
  defp share(mps), do: percent(mps, @all_mps)

  defp percent(part, whole) do
    value = part * 100 / whole

    cond do
      value == 0 -> "0%"
      value < 0.01 -> "under 0.01%"
      true -> "#{:erlang.float_to_binary(value, decimals: 2)}%"
    end
  end

  # An amount as the chain gives it, with every digit: an exact price can run
  # past the default precision Decimal reads.
  defp exact(%Decimal{} = decimal), do: decimal
  defp exact(text) when is_binary(text), do: Decimal.new(text, max_digits: :infinity)

  defp plain(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  defp plain(text) when is_binary(text), do: text

  defp grouped(nil), do: "—"
  defp grouped(block), do: block |> Integer.to_string() |> Amounts.grouped()
end
