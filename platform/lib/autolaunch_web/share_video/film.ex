defmodule AutolaunchWeb.ShareVideo.Film do
  @moduledoc """
  Draws a share video from its story (`AutolaunchWeb.ShareVideo.Story`) and
  encodes it as an MP4: 1080 by 1350, 30 frames a second, ten seconds, H.264
  in yuv420p with its index at the front, so it plays as soon as it starts
  loading.

  The frame sits inside a tangerine border that widens into a band reading
  autolaunch.sh at the foot: a phase word over a chart, and a strip with the
  token's logo, words and figures under it. The chart draws the auction's clearing
  price as blue steps, then the pool's price as a smooth tangerine line from
  graduation, its tip carrying a pulsing dot and the FDV it stands at. A
  wallet's own bids, buys and sells pop in on the line, its first stake drops
  a gold line to the floor, and its earnings rise in gold from there. The card
  counts along with the line, and while an auction runs its pill counts down
  to the end. The video holds on today's figures.

  What never changes is drawn once: the border, the field, the grid, the
  strip with its logo and words, and the band. Each frame draws only the chart's moving parts
  and the figures, lays them over the still layers and hands the pixels to
  ffmpeg, which runs at low priority so pages keep their share of the
  machine.
  """

  alias AutolaunchWeb.ShareCard.Draw
  alias AutolaunchWeb.TokenDisplay
  alias Vix.Vips.{Image, Operation}

  @width 1080
  @height 1350
  @fps 30
  @frames 300

  @field "#111110"
  @strip "#1c1c1a"
  @edge "#2e2d29"
  @platinum "#e5e3d2"
  @muted "#9a988c"
  @tangerine "#ff5b19"
  @blue "#8fc3ff"
  @gold "#f5c84c"
  @green "#3ddc84"
  @red "#ff4d4d"

  # The tangerine border and the dark panel inside it.
  @border 28
  @band_y 1222

  # The chart.
  @x0 76
  @x1 1004
  @top 150
  @floor 700
  @high @top + 70
  @low @floor - 40
  @chart_y 110
  @chart_h 680
  @auction_share 0.32
  @samples 180

  # The strip.
  @strip_x 56
  @strip_y 846
  @strip_w @width - 2 * @strip_x
  @strip_h 300
  @inset 40
  @logo 168
  @logo_x @strip_x + @inset
  @logo_y @strip_y + div(@strip_h - @logo, 2)
  @words_x @logo_x + @logo + 36
  @right @strip_x + @strip_w - @inset
  @pill_h 42
  @chain_mark_h 26
  @words_w 340

  # The timeline, in frames.
  @auction_from 10
  @auction_to 100
  @trading_from 112
  @trading_to 222
  @pop 8
  @note_hold 40
  @note_fade 10

  @doc """
  The video's MP4 bytes, with what drawing and encoding it took: the time
  in milliseconds and the most memory the BEAM held while it ran.
  """
  @spec render(map()) :: {:ok, binary(), map()} | {:error, term()}
  # The path is the site's own temporary file, never named by a request.
  # sobelow_skip ["Traversal.FileModule"]
  def render(story) do
    started = System.monotonic_time(:millisecond)
    film = prepare(story)
    path = Path.join(System.tmp_dir!(), "share-video-#{System.unique_integer([:positive])}.mp4")

    try do
      with {:ok, peak} <- encode(film, path),
           {:ok, mp4} <- File.read(path) do
        {:ok, mp4,
         %{
           ms: System.monotonic_time(:millisecond) - started,
           peak_bytes: peak,
           bytes: byte_size(mp4)
         }}
      end
    after
      File.rm(path)
    end
  end

  # --- what the frames share --------------------------------------------------

  # A launch that has graduated splits the chart between its auction and its
  # trading at graduation; one still in its auction gives the auction the
  # whole chart, up to now.
  defp prepare(story) do
    auction? = match?([_ | _], story.auction_line)
    graduates? = match?([_ | _], story.trade_line)
    graduated_at = if graduates?, do: story.trade_line |> hd() |> elem(0), else: story.now
    started_at = if auction?, do: story.auction_line |> hd() |> elem(0), else: graduated_at
    series = if graduates?, do: smooth(story.trade_line, graduated_at, story.now), else: []
    prices = Enum.map(story.auction_line, &elem(&1, 1)) ++ Enum.map(series, &elem(&1, 1))

    film = %{
      story: story,
      auction?: auction?,
      graduates?: graduates?,
      started_at: started_at,
      graduated_at: graduated_at,
      series: series,
      range: Enum.min_max(prices),
      stake: story.stake
    }

    film =
      Map.merge(film, %{
        stake_frame: story.stake && first_frame(film, story.stake.at),
        earnings_h: story.stake && earnings_height(film),
        labels: labels(film),
        stills: stills(story),
        mark_w: Draw.mark_width(Draw.chain(story.auction), @chain_mark_h),
        words: words(story)
      })

    Map.put(film, :marks, film |> marks(story.marks) |> placed(film))
  end

  # How high the earnings line may rise: a quarter of the chart, kept clear of
  # the price line after the stake.
  defp earnings_height(film) do
    lowest =
      film.series
      |> Enum.filter(fn {at, _price} -> at >= film.stake.at end)
      |> Enum.map(fn {_at, price} -> y(film, price) end)
      |> Enum.max(fn -> @floor end)

    max(min(0.25 * (@floor - @top), @floor - lowest - 44), 40)
  end

  # The first frame the line's tip stands at or past `at`.
  defp first_frame(film, at), do: Enum.find(0..(@frames - 1), @frames, &(tip(film, &1) >= at))

  # The pool's price, resampled evenly across the trading time and eased
  # into a smooth line that still starts and ends at the exact prices.
  defp smooth(line, from, to) do
    steps =
      for index <- 0..(@samples - 1) do
        at = from + (to - from) * index / (@samples - 1)
        {at, step_value(line, at)}
      end

    values = List.to_tuple(Enum.map(steps, &elem(&1, 1)))
    last = @samples - 1

    steps
    |> Enum.with_index()
    |> Enum.map(fn
      {{at, _value}, 0} ->
        {at, line |> hd() |> elem(1)}

      {{at, _value}, ^last} ->
        {at, line |> List.last() |> elem(1)}

      {{at, _value}, index} ->
        window = for i <- max(index - 7, 0)..min(index + 7, last), do: elem(values, i)
        {at, Enum.sum(window) / length(window)}
    end)
  end

  # The price standing at `at`: the last one set at or before it.
  defp step_value([{_at, first} | _rest] = line, at) do
    Enum.reduce_while(line, first, fn {set_at, price}, standing ->
      if set_at <= at, do: {:cont, price}, else: {:halt, standing}
    end)
  end

  # Each bid, buy and sell as a dot on the line, with its note.
  defp marks(film, marks) do
    marks
    |> Enum.filter(&(&1.at >= film.started_at))
    |> Enum.take(-16)
    |> Enum.with_index()
    |> Enum.map(fn {mark, order} ->
      price = price_at(film, mark.at)
      fdv = money(film.story, price * film.story.supply)
      color = if mark.side == :buy, do: @green, else: @red

      %{
        at: mark.at,
        order: order,
        frame: first_frame(film, mark.at),
        x: x(film, mark.at),
        y: y(film, price),
        color: color,
        letter: text!(if(mark.side == :buy, do: "B", else: "S"), :bold, 18, @field),
        note: text!("#{mark.verb} #{mark.amount} · #{fdv} FDV", :regular, 24, @platinum)
      }
    end)
  end

  # Dates under the chart: the auction's start, graduation and three more
  # through the trading, each where the line reaches it, none crowding the last.
  defp labels(film) do
    span = film.story.now - film.started_at
    format = if span >= 4 * 86_400, do: "%b %-d", else: "%b %-d %H:%M"

    {from, shares} =
      if film.graduates?,
        do: {film.graduated_at, [0.0, 0.34, 0.67, 1.0]},
        else: {film.started_at, [0.34, 0.67, 1.0]}

    times =
      if(film.auction?, do: [film.started_at], else: []) ++
        for(share <- shares, do: from + (film.story.now - from) * share)

    times
    |> Enum.reduce([], fn at, kept ->
      x = x(film, at)

      case kept do
        [%{x: last} | _] when x - last < 170 ->
          kept

        _room ->
          [
            %{
              at: at,
              x: x,
              frame: first_frame(film, at),
              layer: text!(stamp(at, format), :regular, 24, @muted)
            }
            | kept
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp stamp(at, format),
    do: at |> round() |> DateTime.from_unix!() |> Calendar.strftime(format)

  defp words(story) do
    %{
      phases: %{
        auction: text!("Auction", :bold, 40, @blue),
        trading: text!("Trading", :bold, 40, @tangerine),
        staked: story.stake && text!("Staked · earning " <> story.earn_symbol, :bold, 40, @gold)
      },
      graduated: text!("Graduated", :bold, 24, @field),
      stake:
        story.stake &&
          text!(
            "You staked #{amount(story.stake.first)} #{story.token_symbol}",
            :bold,
            24,
            @field
          ),
      labels: %{
        auction: [
          text!("Clearing price", :regular, 26, @muted),
          text!("Price", :regular, 26, @muted)
        ],
        trading: [text!("FDV", :regular, 26, @muted), text!("Price", :regular, 26, @muted)],
        staked: [text!("Staked", :regular, 26, @muted), text!("Earned", :regular, 26, @muted)]
      }
    }
  end

  # The border, the field, the grid, the strip and the band, kept in memory
  # for every frame: with the auction's pill, with the graduated one, and for
  # an auction still running with the chain's mark alone, its pill counting
  # down on every frame.
  defp stills(story) do
    auction = story.auction
    chain = Draw.chain(auction)
    color = Draw.color(auction.image_color)
    {:ok, logo} = Draw.logo(auction, @logo)
    name = name(Draw.plain(auction.title))
    ticker = fit!(story.ticker, :regular, 34, @muted, @words_w)
    site = text!("autolaunch.sh", :pixel, 52, @field)
    initial = if logo, do: nil, else: initial(auction.token_symbol)

    words =
      [
        {ticker, @words_x, @strip_y + 112},
        {site, @border + 28, @band_y + div(@height - @band_y - Image.height(site), 2)}
      ] ++
        if(name, do: [{name, @words_x, @strip_y + 40}], else: []) ++
        if(initial,
          do: [
            {initial, @logo_x + div(@logo - Image.width(initial), 2),
             @logo_y + div(@logo - Image.height(initial), 2)}
          ],
          else: []
        )

    for {kind, pill_words, pill_color} <- [
          {:auction, "Auction", @blue},
          {:graduated, "Graduated", @tangerine},
          {:running, nil, nil}
        ],
        into: %{} do
      {badge, pill} = still_pill(pill_words, pill_color)
      {:ok, {canvas, _flags}} = Operation.svgload_buffer(still_svg(chain, color, logo, pill))
      {:ok, still} = Image.copy_memory(flat(canvas, words ++ badge))
      {kind, still}
    end
  end

  defp still_pill(nil, _color), do: {[], nil}

  defp still_pill(words, color) do
    badge = text!(words, :bold, 24, color)
    width = Image.width(badge) + 36

    {[{badge, badge_x(), pill_y() + div(@pill_h - Image.height(badge), 2)}],
     %{color: color, width: width}}
  end

  defp name(""), do: nil

  defp name(words),
    do: Enum.find_value([54, 48, 42], &fits(words, &1)) || fit!(words, :bold, 42, @platinum, 400)

  defp fits(words, size) do
    layer = text!(words, :bold, size, @platinum)
    if Image.width(layer) <= 400, do: layer
  end

  defp initial(symbol) do
    case symbol |> Draw.plain() |> String.first() do
      nil -> nil
      letter -> text!(String.upcase(letter), :pixel, 76, @field)
    end
  end

  defp badge_x, do: @words_x + 18
  defp pill_y, do: @strip_y + 196

  defp still_svg(chain, color, logo, pill) do
    mark_w = Draw.mark_width(chain, @chain_mark_h)
    grid = for row <- 0..3, do: @top + row * div(@floor - @top, 4)
    # A running auction's mark leads the row, so its counting pill can grow
    # to the right of it.
    mark_x = if pill, do: badge_x() + pill.width + 6, else: badge_x() - 18
    panel_w = @width - 2 * @border
    panel_h = @band_y - @border

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">
      <defs>
        <radialGradient id="glow" cx="#{(@logo_x + div(@logo, 2)) / @width}" cy="#{(@logo_y + div(@logo, 2)) / @height}" r="0.55">
          <stop offset="0" stop-color="#{color}" stop-opacity="0.12"/>
          <stop offset="1" stop-color="#{color}" stop-opacity="0"/>
        </radialGradient>
        <clipPath id="round"><circle cx="#{@logo_x + div(@logo, 2)}" cy="#{@logo_y + div(@logo, 2)}" r="#{div(@logo, 2)}"/></clipPath>
      </defs>
      <rect width="#{@width}" height="#{@height}" fill="#{@tangerine}"/>
      <rect x="#{@border}" y="#{@border}" width="#{panel_w}" height="#{panel_h}" rx="48" fill="#{@field}"/>
      <rect x="#{@border}" y="#{@border}" width="#{panel_w}" height="#{panel_h}" rx="48" fill="url(#glow)"/>
      #{Enum.map_join(grid, "\n", &~s|<line x1="#{@x0}" y1="#{&1}" x2="#{@x1}" y2="#{&1}" stroke="#{@edge}" stroke-width="2" stroke-dasharray="2 9" stroke-linecap="round"/>|)}
      <line x1="#{@x0}" y1="#{@floor}" x2="#{@x1}" y2="#{@floor}" stroke="#{@edge}" stroke-width="2"/>
      <rect x="#{@strip_x}" y="#{@strip_y}" width="#{@strip_w}" height="#{@strip_h}" rx="40"
        fill="#{@strip}" stroke="#{@edge}" stroke-width="2"/>
      #{logo_svg(logo, color)}
      #{pill_svg(pill)}
      <image x="#{mark_x}" y="#{pill_y() + div(@pill_h - @chain_mark_h, 2)}" width="#{mark_w}"
        height="#{@chain_mark_h}" href="data:image/svg+xml;base64,#{Base.encode64(Draw.chain_mark(chain))}"/>
    </svg>
    """
  end

  defp pill_svg(nil), do: ""

  defp pill_svg(pill),
    do:
      ~s|<rect x="#{badge_x() - 18}" y="#{pill_y()}" width="#{pill.width}" height="#{@pill_h}" rx="#{div(@pill_h, 2)}" fill="none" stroke="#{pill.color}" stroke-width="2"/>|

  defp logo_svg(nil, color),
    do:
      ~s|<circle cx="#{@logo_x + div(@logo, 2)}" cy="#{@logo_y + div(@logo, 2)}" r="#{div(@logo, 2)}" fill="#{color}"/>|

  defp logo_svg(png, _color),
    do:
      ~s|<image x="#{@logo_x}" y="#{@logo_y}" width="#{@logo}" height="#{@logo}" clip-path="url(#round)" href="data:image/png;base64,#{Base.encode64(png)}"/>|

  # --- one frame ----------------------------------------------------------------

  defp frame(film, index) do
    tip = tip(film, index)
    graduated? = film.graduates? and tip >= film.graduated_at
    staked? = film.stake != nil and tip >= film.stake.at
    price = price_at(film, tip)
    {tip_x, tip_y} = {x(film, tip), y(film, price)}
    tag = text!("#{money(film.story, price * film.story.supply)} FDV", :bold, 26, @field)
    tag_color = if graduated?, do: @tangerine, else: @blue
    {earned, earned_tag, earned_box} = earnings(film, tip, tip_x, staked?)

    taken =
      showing_notes(film, index) ++
        if(staked?, do: Enum.reject([stake_box(film), earned_box], &is_nil/1), else: [])

    tag_box = tag_box(tip_x, tip_y, tag, taken)

    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@chart_h}" viewBox="0 #{@chart_y} #{@width} #{@chart_h}">
      <defs>
        <linearGradient id="blue" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@blue}" stop-opacity="0.16"/>
          <stop offset="1" stop-color="#{@blue}" stop-opacity="0.02"/>
        </linearGradient>
        <linearGradient id="tangerine" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@tangerine}" stop-opacity="0.26"/>
          <stop offset="1" stop-color="#{@tangerine}" stop-opacity="0.02"/>
        </linearGradient>
        <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@gold}" stop-opacity="0.30"/>
          <stop offset="1" stop-color="#{@gold}" stop-opacity="0.04"/>
        </linearGradient>
      </defs>
      #{staircase_svg(film, tip)}
      #{graduation_svg(film, index, graduated?)}
      #{trading_svg(film, tip)}
      #{earnings_svg(film, tip, staked?)}
      #{stake_svg(film, tip, index, staked?)}
      #{marks_svg(film, index)}
      #{notes_svg(film, index)}
      #{tip_svg(tip_x, tip_y, tag_color, index)}
      #{pill_svg(tag_box, tag_color)}
      #{if earned_box, do: pill_svg(earned_box, @gold), else: ""}
    </svg>
    """

    {:ok, {chart, _flags}} = Operation.svgload_buffer(svg)

    still = still(film, graduated?)

    layers =
      [{chart, 0, @chart_y}] ++
        top_row(film, staked?, graduated?) ++
        label_layers(film, index) ++
        mark_layers(film, index) ++
        graduated_layers(film, index, graduated?) ++
        stake_layers(film, tip, index, staked?) ++
        [box_text(tag_box, tag)] ++
        if(earned_box, do: [box_text(earned_box, earned_tag)], else: []) ++
        stat_layers(film, price, earned, graduated?, staked?, index) ++
        countdown_layers(film, tip)

    flat(still, layers)
  end

  defp still(%{stills: stills}, true), do: stills.graduated
  defp still(%{graduates?: true, stills: stills}, false), do: stills.auction
  defp still(%{stills: stills}, false), do: stills.running

  # What the wallet has earned by the tip, with its gold tag at the tip of
  # the earnings line once the stake is on the chart.
  defp earnings(%{stake: nil}, _tip, _tip_x, _staked?), do: {nil, nil, nil}
  defp earnings(film, tip, _tip_x, false), do: {earned(film, tip), nil, nil}

  defp earnings(film, tip, tip_x, true) do
    earned = earned(film, tip)
    tag = text!("#{amount(earned)} #{film.story.earn_symbol}", :bold, 24, @field)
    box = box_beside({tip_x, earned_y(film, tip)}, tag, 14)
    stake = stake_box(film)

    # Kept above the stake's tag when the two would meet.
    box = if meet?(box, stake), do: %{box | y: stake.y - box.h - 8}, else: box
    {earned, tag, box}
  end

  # When the tip stands where on the timeline: through the auction, held at
  # graduation, through the trading, then still at now.
  defp tip(%{graduates?: false} = film, index),
    do:
      film.started_at +
        ease(progress(index, @auction_from, @trading_to)) * (film.story.now - film.started_at)

  defp tip(film, index) do
    from = if film.auction?, do: @trading_from, else: @auction_from

    cond do
      film.auction? and index <= @auction_to ->
        film.started_at +
          ease(progress(index, @auction_from, @auction_to)) *
            (film.graduated_at - film.started_at)

      index < from ->
        film.graduated_at

      true ->
        film.graduated_at +
          ease(progress(index, from, @trading_to)) * (film.story.now - film.graduated_at)
    end
  end

  defp progress(index, from, to), do: min(max((index - from) / (to - from), 0.0), 1.0)

  defp ease(p), do: -(:math.cos(:math.pi() * p) - 1) / 2

  defp pop(p) do
    p = min(max(p, 0.0), 1.0)
    1 + 2.70158 * :math.pow(p - 1, 3) + 1.70158 * :math.pow(p - 1, 2)
  end

  defp price_at(film, at) do
    if at < film.graduated_at or not film.graduates?,
      do: step_value(film.story.auction_line, at),
      else: between(film.series, at)
  end

  # Along a line of `{at, value}` points, between the two around `at`.
  defp between(points, at) do
    case Enum.split_while(points, fn {point_at, _value} -> point_at < at end) do
      {[], [{_at, value} | _rest]} -> value
      {before, []} -> before |> List.last() |> elem(1)
      {before, [{b, vb} | _rest]} -> between_two(List.last(before), {b, vb}, at)
    end
  end

  defp between_two({a, va}, {b, vb}, at), do: va + (vb - va) * (at - a) / (b - a)

  defp x(film, at) do
    plot = @x1 - @x0

    auction_w =
      cond do
        not film.auction? -> 0
        film.graduates? -> plot * @auction_share
        true -> plot
      end

    if at <= film.graduated_at and film.auction? do
      span = max(film.graduated_at - film.started_at, 1)
      @x0 + (at - film.started_at) / span * auction_w
    else
      span = max(film.story.now - film.graduated_at, 1)
      @x0 + auction_w + (at - film.graduated_at) / span * (plot - auction_w)
    end
  end

  defp y(film, price) do
    {lo, hi} = film.range

    if hi == lo,
      do: (@high + @low) / 2,
      else: @high + (hi - price) / (hi - lo) * (@low - @high)
  end

  defp earned(film, at), do: between(film.stake.earned_curve, at) * film.stake.earned

  defp earned_y(film, at) do
    share = if film.stake.earned > 0, do: earned(film, at) / film.stake.earned, else: 0.0
    @floor - share * film.earnings_h
  end

  # --- the chart's moving parts -------------------------------------------------

  defp staircase_svg(%{auction?: false}, _tip), do: ""

  defp staircase_svg(film, tip) do
    until = min(tip, film.graduated_at)
    shown = Enum.filter(film.story.auction_line, fn {at, _price} -> at <= until end)

    case shown do
      [] ->
        ""

      [{first_at, first_price} | _rest] ->
        steps =
          shown
          |> Enum.chunk_every(2, 1)
          |> Enum.map_join(" ", fn
            [_point, {next_at, next_price}] ->
              "H#{n(x(film, next_at))} V#{n(y(film, next_price))}"

            [_last] ->
              "H#{n(x(film, until))}"
          end)

        start = "M#{n(x(film, first_at))} #{n(y(film, first_price))}"
        line = "#{start} #{steps}"

        """
        <path d="#{line} V#{@floor} H#{n(x(film, first_at))} Z" fill="url(#blue)"/>
        <path d="#{line}" fill="none" stroke="#{@blue}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>
        """
    end
  end

  defp graduation_svg(_film, _index, false), do: ""

  defp graduation_svg(%{auction?: false}, _index, true), do: ""

  defp graduation_svg(film, index, true) do
    gx = n(x(film, film.graduated_at))
    scale = pop((index - @auction_to) / @pop)
    %{w: w, h: h} = graduated_box(film)

    """
    <line x1="#{gx}" y1="#{@top + 28}" x2="#{gx}" y2="#{@floor}" stroke="#{@tangerine}" stroke-width="2" stroke-dasharray="8 8" opacity="0.8"/>
    <g transform="translate(#{gx} #{@top + 9}) scale(#{n(scale)})">
      <rect x="#{-w / 2}" y="#{-h / 2}" width="#{w}" height="#{h}" rx="#{h / 2}" fill="#{@tangerine}"/>
    </g>
    """
  end

  defp graduated_layers(%{auction?: false}, _index, _graduated?), do: []
  defp graduated_layers(_film, _index, false), do: []

  defp graduated_layers(film, index, true) do
    if index >= @auction_to + div(@pop, 2) do
      words = film.words.graduated
      gx = round(x(film, film.graduated_at))
      [{words, gx - div(Image.width(words), 2), @top + 9 - div(Image.height(words), 2)}]
    else
      []
    end
  end

  defp trading_svg(film, tip) when tip <= film.graduated_at, do: ""

  defp trading_svg(film, tip) do
    points =
      film.series
      |> Enum.filter(fn {at, _price} -> at < tip end)
      |> Enum.map(fn {at, price} -> {x(film, at), y(film, price)} end)
      |> Kernel.++([{x(film, tip), y(film, price_at(film, tip))}])

    line = curve(points)
    {first_x, _} = hd(points)
    {last_x, _} = List.last(points)

    """
    <path d="#{line} L#{n(last_x)} #{@floor} L#{n(first_x)} #{@floor} Z" fill="url(#tangerine)"/>
    <path d="#{line}" fill="none" stroke="#{@tangerine}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>
    """
  end

  # A smooth path through the points (Catmull-Rom as cubic Béziers).
  defp curve([{x, y}]), do: "M#{n(x)} #{n(y)}"

  defp curve(points) do
    padded = List.to_tuple([hd(points)] ++ points ++ [List.last(points), List.last(points)])
    count = length(points)
    {x, y} = hd(points)

    segments =
      for i <- 1..(count - 1) do
        {x0, y0} = elem(padded, i - 1)
        {x1, y1} = elem(padded, i)
        {x2, y2} = elem(padded, i + 1)
        {x3, y3} = elem(padded, i + 2)

        "C#{n(x1 + (x2 - x0) / 6)} #{n(y1 + (y2 - y0) / 6)} #{n(x2 - (x3 - x1) / 6)} #{n(y2 - (y3 - y1) / 6)} #{n(x2)} #{n(y2)}"
      end

    "M#{n(x)} #{n(y)} " <> Enum.join(segments, " ")
  end

  defp earnings_svg(_film, _tip, false), do: ""

  defp earnings_svg(film, tip, true) do
    from = film.stake.at

    points =
      film.series
      |> Enum.filter(fn {at, _price} -> at > from and at < tip end)
      |> Enum.map(fn {at, _price} -> {x(film, at), earned_y(film, at)} end)

    points = [{x(film, from), @floor * 1.0} | points] ++ [{x(film, tip), earned_y(film, tip)}]
    line = curve(points)
    {first_x, _} = hd(points)
    {last_x, _} = List.last(points)

    """
    <path d="#{line} L#{n(last_x)} #{@floor} L#{n(first_x)} #{@floor} Z" fill="url(#gold)"/>
    <path d="#{line}" fill="none" stroke="#{@gold}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>
    """
  end

  defp stake_svg(_film, _tip, _index, false), do: ""

  defp stake_svg(film, _tip, index, true) do
    sx = x(film, film.stake.at)
    sy = y(film, price_at(film, film.stake.at))
    scale = pop((index - film.stake_frame) / @pop)
    box = stake_box(film)

    """
    <line x1="#{n(sx)}" y1="#{n(sy)}" x2="#{n(sx)}" y2="#{@floor}" stroke="#{@gold}" stroke-width="3" stroke-dasharray="7 7"/>
    <circle cx="#{n(sx)}" cy="#{n(sy)}" r="#{n(11 * scale)}" fill="#{@gold}" stroke="#{@field}" stroke-width="3"/>
    #{pill_svg(box, @gold)}
    """
  end

  defp stake_layers(_film, _tip, _index, false), do: []

  defp stake_layers(film, _tip, _index, true), do: [box_text(stake_box(film), film.words.stake)]

  defp stake_box(film) do
    sx = x(film, film.stake.at)
    words = film.words.stake
    w = Image.width(words) + 28
    left = if sx + 12 + w > @width - 16, do: sx - 12 - w, else: sx + 12
    %{x: left, y: @floor - 54, w: w, h: 38}
  end

  defp marks_svg(film, index) do
    film.marks
    |> Enum.filter(&(&1.frame <= index))
    |> Enum.map_join("\n", fn mark ->
      ~s|<circle cx="#{n(mark.x)}" cy="#{n(mark.y)}" r="#{n(15 * pop((index - mark.frame) / @pop))}" fill="#{mark.color}" stroke="#{@field}" stroke-width="3"/>|
    end)
  end

  # A dot's letter once the dot has nearly reached its size and until a later
  # dot covers it, and its note while the note shows.
  defp mark_layers(film, index) do
    letters =
      film.marks
      |> Enum.filter(&(index - &1.frame >= div(@pop, 2) and not covered?(&1, film.marks, index)))
      |> Enum.map(fn %{letter: letter} = mark ->
        {letter, round(mark.x) - div(Image.width(letter), 2),
         round(mark.y) - div(Image.height(letter), 2)}
      end)

    letters ++ Enum.flat_map(film.marks, &note_layer(&1, index))
  end

  defp covered?(mark, marks, index),
    do:
      Enum.any?(marks, fn later ->
        later.order > mark.order and later.frame <= index and
          :math.sqrt(:math.pow(later.x - mark.x, 2) + :math.pow(later.y - mark.y, 2)) < 24
      end)

  defp notes_svg(film, index) do
    film.marks
    |> Enum.map(fn mark -> {mark, note_opacity(mark, index)} end)
    |> Enum.filter(fn {_mark, opacity} -> opacity > 0 end)
    |> Enum.map_join("\n", fn {mark, opacity} ->
      box = mark.box

      ~s|<rect x="#{n(box.x)}" y="#{n(box.y)}" width="#{box.w}" height="#{box.h}" rx="12" fill="#{@strip}" stroke="#{mark.color}" stroke-width="2" opacity="#{n(opacity)}"/>|
    end)
  end

  defp note_layer(mark, index) do
    opacity = note_opacity(mark, index)

    if opacity > 0 do
      box = mark.box
      [faded(box_text(box, mark.note), opacity)]
    else
      []
    end
  end

  defp note_opacity(mark, index) do
    age = index - mark.frame

    cond do
      age < 0 -> 0.0
      age < @pop -> age / @pop
      age < @pop + @note_hold -> 1.0
      true -> max(1.0 - (age - @pop - @note_hold) / @note_fade, 0.0)
    end
  end

  # Each note's place, chosen once so it never jumps: above its dot, or
  # higher, or below it, wherever it clears the Graduated tag and every note
  # showing at the same time.
  defp placed(marks, film) do
    taken = if film.auction? and film.graduates?, do: [graduated_box(film)], else: []

    {placed, _taken} =
      Enum.map_reduce(marks, taken, fn mark, taken ->
        showing = Enum.filter(taken, &overlaps_in_time?(&1, mark))
        box = mark |> note_boxes() |> Enum.find(&clear?(&1, showing)) || hd(note_boxes(mark))
        {Map.put(mark, :box, box), [Map.put(box, :frame, mark.frame) | taken]}
      end)

    placed
  end

  defp note_boxes(mark) do
    w = Image.width(mark.note) + 28
    h = 40
    x = min(max(mark.x - w / 2, 16), @width - 16 - w)

    above =
      for y <-
            Stream.iterate(mark.y - 30 - h, &(&1 - h - 6))
            |> Enum.take_while(&(&1 >= @chart_y + 4)),
          do: y

    below =
      for y <-
            Stream.iterate(mark.y + 26, &(&1 + h + 6)) |> Enum.take_while(&(&1 + h <= @floor - 4)),
          do: y

    Enum.map(above ++ below, &%{x: x, y: &1, w: w, h: h})
  end

  defp overlaps_in_time?(%{frame: frame}, mark),
    do: abs(frame - mark.frame) < @pop + @note_hold + @note_fade

  defp overlaps_in_time?(_always_there, _mark), do: true

  defp clear?(box, taken), do: not Enum.any?(taken, &meet?(box, &1))

  defp meet?(a, b),
    do:
      a.x < b.x + b.w + 6 and b.x < a.x + a.w + 6 and a.y < b.y + b.h + 6 and b.y < a.y + a.h + 6

  defp graduated_box(film) do
    w = Image.width(film.words.graduated) + 28
    %{x: x(film, film.graduated_at) - w / 2, y: @top + 9 - 19, w: w, h: 38}
  end

  defp tip_svg(x, y, color, index) do
    phase = rem(index, @fps) / @fps

    """
    <circle cx="#{n(x)}" cy="#{n(y)}" r="#{n(9 + 16 * phase)}" fill="#{color}" opacity="#{n(0.45 * (1 - phase))}"/>
    <circle cx="#{n(x)}" cy="#{n(y)}" r="9" fill="#{color}" stroke="#{@field}" stroke-width="3"/>
    """
  end

  # The tip's tag: above and right of the dot if it fits there, otherwise
  # at the first other corner clear of the notes showing.
  defp tag_box(x, y, tag, notes) do
    w = Image.width(tag) + 28
    h = 40

    boxes =
      for top <- [y - 26 - h, y + 18],
          left <- [x + 18, x - 18 - w],
          left >= 16 and left + w <= @width - 16 and top >= @chart_y + 4 and top + h <= @floor,
          do: %{x: left, y: top, w: w, h: h}

    Enum.find(boxes, &clear?(&1, notes)) || hd(boxes)
  end

  defp showing_notes(film, index),
    do: for(mark <- film.marks, note_opacity(mark, index) > 0, do: mark.box)

  defp box_beside({x, y}, words, gap) do
    w = Image.width(words) + 28
    h = 38
    left = if x + gap + w > @width - 16, do: x - gap - w, else: x + gap
    %{x: left, y: min(y + 8, @floor - h - 6), w: w, h: h}
  end

  defp pill_svg(box, color),
    do:
      ~s|<rect x="#{n(box.x)}" y="#{n(box.y)}" width="#{box.w}" height="#{box.h}" rx="#{box.h / 2}" fill="#{color}"/>|

  defp box_text(box, words),
    do:
      {words, round(box.x + (box.w - Image.width(words)) / 2),
       round(box.y + (box.h - Image.height(words)) / 2)}

  # --- the words that move ------------------------------------------------------

  defp top_row(film, staked?, graduated?) do
    phase =
      cond do
        staked? -> film.words.phases.staked
        graduated? -> film.words.phases.trading
        true -> film.words.phases.auction
      end

    [{phase, @border + 36, 60}]
  end

  # Each date slides up into place as the line reaches it.
  defp label_layers(film, index) do
    film.labels
    |> Enum.filter(&(&1.frame <= index))
    |> Enum.map(fn label ->
      shown = min((index - label.frame + 1) / @pop, 1.0)
      w = Image.width(label.layer)
      left = round(min(max(label.x - w / 2, @x0 - 16), @x1 + 16 - w))
      faded({label.layer, left, @floor + 14 + round(10 * (1 - shown))}, shown)
    end)
  end

  # The card's two figures as the line stands: a stake's own figures in
  # gold, the FDV and price once trading, and through an auction its clearing
  # price with, while it still runs, the time left as of the line's tip.
  # The card's two figures as the line stands: a stake's own figures in
  # gold, the FDV and price once trading, and through an auction its clearing
  # price and price per token.
  defp stat_layers(film, price, earned, graduated?, staked?, index) do
    story = film.story
    fdv = money(story, price * story.supply)

    rows =
      cond do
        staked? ->
          counted = film.stake.staked * min((index - film.stake_frame) / 18, 1.0)
          [staked, earned_label] = film.words.labels.staked

          [
            {staked, "#{amount(counted)} #{story.token_symbol}", @gold},
            {earned_label, "#{amount(earned)} #{story.earn_symbol}", @gold}
          ]

        graduated? ->
          [fdv_label, price_label] = film.words.labels.trading
          [{fdv_label, fdv, @platinum}, {price_label, money(story, price), @platinum}]

        true ->
          [clearing, price_label] = film.words.labels.auction
          [{clearing, fdv, @platinum}, {price_label, money(story, price), @platinum}]
      end

    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {{label, value, color}, row} ->
      value = figure(value, color)
      top = @strip_y + 40 + row * 124

      [
        {label, @right - Image.width(label), top},
        {value, @right - Image.width(value), top + 32}
      ]
    end)
  end

  # A figure steps down in size until it fits beside the name, and past its
  # last step it is drawn at the size that fits, so a long one is never cut
  # short and never runs into the name.
  defp figure(value, color, sizes \\ [50, 44, 38, 32, 28])

  defp figure(value, color, [size | smaller]) do
    layer = text!(value, :bold, size, color)

    cond do
      Image.width(layer) <= @words_w -> layer
      smaller != [] -> figure(value, color, smaller)
      true -> figure(value, color, [div(size * @words_w, Image.width(layer))])
    end
  end

  # While an auction runs, its pill counts down to the end as of the line's
  # tip, beside the chain's mark; once it cannot, it names where the auction
  # stands.
  defp countdown_layers(%{graduates?: true}, _tip), do: []

  defp countdown_layers(film, tip) do
    words =
      case Draw.standing(film.story.auction, DateTime.from_unix!(round(tip))) do
        {"Time left", left, _color} -> "Ends in " <> left
        {_label, standing, _color} -> standing
      end

    badge = text!(words, :bold, 24, @blue)
    width = Image.width(badge) + 36
    x = badge_x() - 18 + film.mark_w + 24

    {:ok, {pill, _flags}} =
      Operation.svgload_buffer(
        ~s|<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{@pill_h}"><rect x="1" y="1" width="#{width - 2}" height="#{@pill_h - 2}" rx="#{div(@pill_h, 2) - 1}" fill="none" stroke="#{@blue}" stroke-width="2"/></svg>|
      )

    [{pill, x, pill_y()}, {badge, x + 18, pill_y() + div(@pill_h - Image.height(badge), 2)}]
  end

  # --- figures ------------------------------------------------------------------

  defp money(story, value),
    do: Draw.money(decimal(value), story.rate, story.auction)

  defp amount(value), do: TokenDisplay.short(decimal(value))

  # The film's figures are floats, good to 15 significant digits; past them a
  # float only carries its own error (0.00000029 * 100,000,000 is
  # 28.999999999999996), which cutting would show a cent low.
  defp decimal(value) when value <= 0, do: Decimal.new(0)

  defp decimal(value),
    do:
      Decimal.Context.with(%Decimal.Context{precision: 15}, fn ->
        (value * 1.0) |> Decimal.from_float() |> Decimal.add(0)
      end)

  defp n(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  # --- drawing and encoding -------------------------------------------------------

  defp text!(words, weight, size, color) do
    {:ok, layer} = Draw.layer(words, weight, size, color)
    layer
  end

  defp fit!(words, weight, size, color, max) do
    {:ok, layer} = Draw.fit(words, weight, size, color, max)
    layer
  end

  defp faded({layer, x, y}, opacity) when opacity >= 1.0, do: {layer, x, y}

  defp faded({layer, x, y}, opacity) do
    {:ok, alpha} = Operation.linear(layer, [1.0, 1.0, 1.0, opacity], [0.0, 0.0, 0.0, 0.0])
    {:ok, alpha} = Operation.cast(alpha, :VIPS_FORMAT_UCHAR)
    {alpha, x, y}
  end

  # Every layer over the base in one pass.
  defp flat(base, layers) do
    {:ok, image} =
      Operation.composite(
        [base | Enum.map(layers, &elem(&1, 0))],
        List.duplicate(:VIPS_BLEND_MODE_OVER, length(layers)),
        x: Enum.map(layers, &elem(&1, 1)),
        y: Enum.map(layers, &elem(&1, 2))
      )

    image
  end

  defp pixels(image) do
    {:ok, rgb} = Operation.extract_band(image, 0, n: 3)
    {:ok, rgb} = Operation.cast(rgb, :VIPS_FORMAT_UCHAR)
    {:ok, bytes} = Image.write_to_binary(rgb)
    bytes
  end

  # Frames go to ffmpeg as raw RGB on its input, at low priority. A port
  # cannot close its input on its own, so `head` passes on exactly the
  # frames' bytes and then closes ffmpeg's input, and ffmpeg writes the file
  # and exits. The highest memory the BEAM reached is kept for the
  # measurement.
  defp encode(film, path) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args:
          ["-c", ~s|head -c "$0" \| nice -n 10 "$@"|, "#{@frames * @width * @height * 3}"] ++
            ffmpeg(path)
      ])

    peak =
      Enum.reduce(0..(@frames - 1), 0, fn index, peak ->
        true = Port.command(port, film |> frame(index) |> pixels())
        max(peak, :erlang.memory(:total))
      end)

    finished(port, peak, [])
  end

  defp finished(port, peak, said) do
    receive do
      {^port, {:data, words}} ->
        finished(port, peak, [words | said])

      {^port, {:exit_status, 0}} ->
        {:ok, peak}

      {^port, {:exit_status, status}} ->
        {:error, {:ffmpeg, status, said |> Enum.reverse() |> IO.iodata_to_binary()}}
    after
      120_000 ->
        Port.close(port)
        {:error, :ffmpeg_timeout}
    end
  end

  defp ffmpeg(path),
    do: [
      System.find_executable("ffmpeg"),
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "rgb24",
      "-s",
      "#{@width}x#{@height}",
      "-r",
      "#{@fps}",
      "-i",
      "pipe:0",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "21",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      "-threads",
      "1",
      "-y",
      path
    ]
end
