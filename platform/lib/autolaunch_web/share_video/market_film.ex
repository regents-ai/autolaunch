defmodule AutolaunchWeb.ShareVideo.MarketFilm do
  @moduledoc """
  Draws the share video of a stock market on Autolaunch from its story
  (`AutolaunchWeb.ShareVideo.MarketStory`), encoded as every share video is
  (`AutolaunchWeb.ShareVideo.Canvas`), in the launch video's frame: the
  tangerine border and its autolaunch.sh band, a chart, and a strip with the
  stock's logo, the product's name and two figures.

  The stock's price draws itself from left to right, its tip carrying a
  pulsing dot and the price it stands at. For covered calls each open strike
  rises in as a dashed line with its expiry; for After-hours Exposure the line
  takes the colour of the window it is in, blue after hours and tangerine in
  market hours, and every price the series applied drops in as a gold dot.
  The video then holds on today's figures.

  What never changes is drawn once: the frame, the grid, the legend and the
  strip. Each frame draws only the line, its tip and the strikes or dots so far.
  """

  import AutolaunchWeb.ShareVideo.Canvas,
    only: [
      text!: 4,
      faded: 2,
      flat: 2,
      svg!: 1,
      n: 1,
      progress: 3,
      ease: 1,
      figure: 3,
      tip_svg: 5
    ]

  alias AutolaunchWeb.ShareCard.Draw
  alias AutolaunchWeb.ShareVideo.{Canvas, MarketStory}
  alias AutolaunchWeb.UsdValue
  alias Vix.Vips.Image

  # The frame `AutolaunchWeb.ShareVideo.Canvas` encodes.
  @width 1080
  @height 1350

  @field "#111110"
  @strip "#1c1c1a"
  @edge "#2e2d29"
  @platinum "#e5e3d2"
  @muted "#9a988c"
  @tangerine "#ff5b19"
  @blue "#8fc3ff"
  @gold "#f5c84c"

  @border 28
  @band_y 1222

  # The chart.
  @x0 76
  @x1 1004
  @top 190
  @floor 700
  @high @top + 40
  @low @floor - 40
  @chart_y 110
  @chart_h 680

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
  @words_w 340
  @pill_h 42
  @chain_mark_h 26

  # The timeline, in frames.
  @line_from 12
  @line_to 210
  @pop 10

  @doc "The video's MP4 bytes, with what drawing and encoding it took."
  @spec render(map()) :: {:ok, binary(), map()} | {:error, term()}
  def render(story) do
    film = prepare(story)
    Canvas.render(&frame(film, &1))
  end

  # --- what the frames share --------------------------------------------------

  defp prepare(story) do
    prices = Enum.map(story.line, &elem(&1, 1)) ++ Enum.map(story.levels, & &1.price)

    film = %{story: story, range: range(prices)}

    Map.merge(film, %{
      levels: Enum.with_index(story.levels, &level_words(&1, &2)),
      still: still(story),
      figures: figure_layers(story.figures),
      phase: phase(story)
    })
  end

  # The stock over the chart and the time it covers.
  defp phase(story) do
    ticker = text!(story.ticker, :bold, 40, @platinum)
    period = text!(period(story.from), :regular, 28, @muted)

    [
      {ticker, @x0, 52},
      {period, @x0 + Image.width(ticker) + 18,
       52 + Image.height(ticker) - Image.height(period) - 4}
    ]
  end

  defp period(from),
    do: "Since " <> (from |> DateTime.from_unix!() |> Calendar.strftime("%a %-d %b"))

  # A flat line still gets room above and below.
  defp range(prices) do
    {low, high} = Enum.min_max(prices)
    pad = if high > low, do: (high - low) * 0.06, else: max(high * 0.02, 0.01)
    {low - pad, high + pad}
  end

  defp level_words(level, index) do
    words = "#{level.label} · #{expiry(level.expiry)}"
    %{level: level, index: index, tag: text!(words, :bold, 24, @field)}
  end

  defp expiry(unix), do: unix |> DateTime.from_unix!() |> Calendar.strftime("%a %-d %b")

  # The border, the field, the grid, the legend, the strip with its logo,
  # words and the pill saying where the market stands, and the band.
  defp still(story) do
    {:ok, logo} = Draw.stock_logo(story.ticker, @logo)
    site = text!("autolaunch.sh", :pixel, 52, @field)
    name = name(story.title)
    ticker = text!("$" <> story.symbol, :regular, 34, @muted)
    badge = text!(story.badge, :bold, 24, @blue)
    pill_w = Image.width(badge) + 36
    initial = if logo, do: nil, else: text!(String.first(story.ticker), :pixel, 76, @field)

    words =
      [
        {name, @words_x, @strip_y + 40},
        {ticker, @words_x, @strip_y + 112},
        {badge, @words_x + 18, @strip_y + 196 + div(@pill_h - Image.height(badge), 2)},
        {site, @border + 28, @band_y + div(@height - @band_y - Image.height(site), 2)}
      ] ++
        legend(story) ++
        if(initial,
          do: [
            {initial, @logo_x + div(@logo - Image.width(initial), 2),
             @logo_y + div(@logo - Image.height(initial), 2)}
          ],
          else: []
        )

    {:ok, still} = Image.copy_memory(flat(svg!(still_svg(story, logo, pill_w)), words))
    still
  end

  defp name(words) do
    Enum.find_value([54, 48, 42], fn size ->
      layer = text!(words, :bold, size, @platinum)
      if Image.width(layer) <= 400, do: layer
    end) || text!(words, :bold, 36, @platinum)
  end

  defp legend(%{kind: :exposure}) do
    after_hours = text!("After hours", :regular, 26, @muted)
    market_hours = text!("Market hours", :regular, 26, @muted)
    right = @x1 - Image.width(market_hours)
    middle = right - 44 - Image.width(after_hours)

    [{after_hours, middle, 122}, {market_hours, right, 122}]
  end

  defp legend(_story), do: []

  defp legend_svg(%{kind: :exposure}) do
    after_w = Image.width(text!("After hours", :regular, 26, @muted))
    market_w = Image.width(text!("Market hours", :regular, 26, @muted))
    market_x = @x1 - market_w - 22
    after_x = market_x - 44 - after_w

    ~s|<circle cx="#{after_x}" cy="138" r="8" fill="#{@blue}"/>| <>
      ~s|<circle cx="#{market_x}" cy="138" r="8" fill="#{@tangerine}"/>|
  end

  defp legend_svg(_story), do: ""

  defp still_svg(story, logo, pill_w) do
    grid = for row <- 0..3, do: @top + row * div(@floor - @top, 4)
    panel_w = @width - 2 * @border
    panel_h = @band_y - @border
    mark_w = Draw.mark_width(:base, @chain_mark_h)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">
      <defs>
        <radialGradient id="glow" cx="#{(@logo_x + div(@logo, 2)) / @width}" cy="#{(@logo_y + div(@logo, 2)) / @height}" r="0.55">
          <stop offset="0" stop-color="#{@tangerine}" stop-opacity="0.12"/>
          <stop offset="1" stop-color="#{@tangerine}" stop-opacity="0"/>
        </radialGradient>
      </defs>
      <rect width="#{@width}" height="#{@height}" fill="#{@tangerine}"/>
      <rect x="#{@border}" y="#{@border}" width="#{panel_w}" height="#{panel_h}" rx="48" fill="#{@field}"/>
      <rect x="#{@border}" y="#{@border}" width="#{panel_w}" height="#{panel_h}" rx="48" fill="url(#glow)"/>
      #{legend_svg(story)}
      #{Enum.map_join(grid, "\n", &~s|<line x1="#{@x0}" y1="#{&1}" x2="#{@x1}" y2="#{&1}" stroke="#{@edge}" stroke-width="2" stroke-dasharray="2 9" stroke-linecap="round"/>|)}
      <line x1="#{@x0}" y1="#{@floor}" x2="#{@x1}" y2="#{@floor}" stroke="#{@edge}" stroke-width="2"/>
      <rect x="#{@strip_x}" y="#{@strip_y}" width="#{@strip_w}" height="#{@strip_h}" rx="40"
        fill="#{@strip}" stroke="#{@edge}" stroke-width="2"/>
      #{logo_svg(logo)}
      <rect x="#{@words_x}" y="#{@strip_y + 196}" width="#{pill_w}" height="#{@pill_h}" rx="#{div(@pill_h, 2)}" fill="none" stroke="#{@blue}" stroke-width="2"/>
      <image x="#{@words_x + pill_w + 12}" y="#{@strip_y + 196 + div(@pill_h - @chain_mark_h, 2)}" width="#{mark_w}"
        height="#{@chain_mark_h}" href="data:image/svg+xml;base64,#{Base.encode64(Draw.chain_mark(:base))}"/>
    </svg>
    """
  end

  # The stock's own mark where the site has one (`Draw.stock_logo/2`); its
  # first letter on a tangerine disc where it has none.
  defp logo_svg(nil),
    do:
      ~s|<circle cx="#{@logo_x + div(@logo, 2)}" cy="#{@logo_y + div(@logo, 2)}" r="#{div(@logo, 2)}" fill="#{@tangerine}"/>|

  defp logo_svg(png),
    do:
      ~s|<image x="#{@logo_x}" y="#{@logo_y}" width="#{@logo}" height="#{@logo}" href="data:image/png;base64,#{Base.encode64(png)}"/>|

  # The two figures, each label over its figure on the right of the strip.
  defp figure_layers(figures) do
    figures
    |> Enum.with_index()
    |> Enum.flat_map(fn {{label, value}, row} ->
      label = text!(label, :regular, 26, @muted)
      value = figure(value, @platinum, @words_w)
      top = @strip_y + 40 + row * 124

      [
        {label, @right - Image.width(label), top},
        {value, @right - Image.width(value), top + 32}
      ]
    end)
  end

  # --- one frame ----------------------------------------------------------------

  defp frame(film, index) do
    story = film.story
    tip = tip(story, index)
    price = MarketStory.price_at(story.line, tip)
    {tip_x, tip_y} = {x(story, tip), y(film, price)}
    tag = text!(dollars(price), :bold, 26, @field)
    tag_box = tag_box(tip_x, tip_y, tag)

    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@chart_h}" viewBox="0 #{@chart_y} #{@width} #{@chart_h}">
      <defs>
        <linearGradient id="under" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@tangerine}" stop-opacity="0.22"/>
          <stop offset="1" stop-color="#{@tangerine}" stop-opacity="0.02"/>
        </linearGradient>
      </defs>
      #{levels_svg(film, index)}
      #{line_svg(film, tip)}
      #{dots_svg(film, tip, index)}
      #{tip_svg(tip_x, tip_y, tip_color(story, tip), @field, index)}
      #{pill_svg(tag_box, tip_color(story, tip))}
      #{Enum.map_join(level_boxes(film, index), "\n", fn {box, _tag, opacity} -> pill_svg(box, @blue, opacity) end)}
    </svg>
    """

    layers =
      [{svg!(svg), 0, @chart_y} | film.phase] ++
        Enum.map(level_boxes(film, index), fn {box, tag, opacity} ->
          faded(box_text(box, tag), opacity)
        end) ++
        [box_text(tag_box, tag)] ++
        film.figures

    flat(film.still, layers)
  end

  # Where the line has reached by frame `index`, eased in and out.
  defp tip(story, index) do
    p = ease(progress(index, @line_from, @line_to))
    story.from + p * (story.now - story.from)
  end

  defp x(story, at),
    do: @x0 + (at - story.from) / max(story.now - story.from, 1) * (@x1 - @x0)

  defp y(%{range: {low, high}}, price),
    do: @low - (price - low) / max(high - low, 1.0e-12) * (@low - @high)

  # --- the line ------------------------------------------------------------------

  # The feed's own steps up to the tip, each price held until the next, so a
  # short dip is drawn as it happened. A step is cut where a window begins, so
  # each part takes the colour of its window.
  # Before the line starts there is nothing to draw.
  defp line_svg(%{story: %{from: from}}, tip) when tip <= from, do: ""

  defp line_svg(film, tip) do
    story = film.story

    edges =
      Enum.flat_map(story.bands, &[&1.from, &1.to])
      |> Enum.concat(Enum.map(story.line, &elem(&1, 0)))
      |> Enum.filter(&(&1 > story.from and &1 < tip))
      |> Enum.concat([story.from, tip])
      |> Enum.map(&(&1 * 1.0))
      |> Enum.sort()
      |> Enum.dedup()

    steps =
      edges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        %{
          from: x(story, from),
          to: x(story, to),
          y: y(film, MarketStory.price_at(story.line, from)),
          color: color_at(story, from)
        }
      end)

    under =
      "M#{n(@x0)} #{@floor} " <>
        Enum.map_join(steps, " ", fn step ->
          "L#{n(step.from)} #{n(step.y)} L#{n(step.to)} #{n(step.y)}"
        end) <>
        " L#{n(List.last(steps).to)} #{@floor} Z"

    fill = if story.kind == :exposure, do: "", else: ~s|<path d="#{under}" fill="url(#under)"/>|

    # Each run of one colour starts where the last ended, so the step between
    # two windows is drawn too.
    {strokes, _end} =
      steps
      |> Enum.chunk_by(& &1.color)
      |> Enum.map_reduce(hd(steps).y, fn [first | _rest] = run, from_y ->
        path =
          Enum.map_join(run, " ", fn step ->
            "L#{n(step.from)} #{n(step.y)} L#{n(step.to)} #{n(step.y)}"
          end)

        {~s|<path d="M#{n(first.from)} #{n(from_y)} #{path}" fill="none" stroke="#{first.color}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>|,
         List.last(run).y}
      end)

    fill <> Enum.join(strokes, "\n")
  end

  # After hours is blue and market hours tangerine; before a series' first
  # close the line is the plain stock's, muted.
  defp color_at(%{kind: :exposure, bands: bands}, at) do
    case Enum.find(bands, &(&1.from <= at and at < &1.to)) do
      %{window: :after} -> @blue
      %{window: :market} -> @tangerine
      nil -> @muted
    end
  end

  defp color_at(_story, _at), do: @tangerine

  defp tip_color(story, tip), do: color_at(story, tip)

  # --- strikes and prints --------------------------------------------------------

  # Each strike rises in as a dashed line, one after another, as the line
  # nears the end of its run.
  defp levels_svg(film, index) do
    Enum.map_join(film.levels, "\n", fn %{level: level, index: slot} ->
      opacity = rise(index, slot)
      y = y(film, level.price)

      ~s|<line x1="#{@x0}" y1="#{n(y)}" x2="#{@x1}" y2="#{n(y)}" stroke="#{@blue}" stroke-width="3" stroke-dasharray="10 10" opacity="#{n(opacity)}"/>|
    end)
  end

  defp level_boxes(film, index) do
    film.levels
    |> Enum.map(fn %{level: level, index: slot, tag: tag} ->
      opacity = rise(index, slot)
      w = Image.width(tag) + 28
      h = Image.height(tag) + 14
      y = round(y(film, level.price)) - h - 6
      {%{x: @x1 - w, y: y, w: w, h: h}, tag, opacity}
    end)
    |> Enum.reject(fn {_box, _tag, opacity} -> opacity <= 0.0 end)
  end

  defp rise(index, slot),
    do: progress(index, @line_to - 60 + slot * 12, @line_to - 60 + slot * 12 + @pop)

  # Each applied price drops in as a gold dot once the line passes it.
  defp dots_svg(film, tip, index) do
    story = film.story

    Enum.map_join(story.dots, "\n", fn {at, price} ->
      if at <= tip do
        passed =
          round((at - story.from) / max(story.now - story.from, 1) * (@line_to - @line_from))

        grow = min(max((index - @line_from - passed) / @pop, 0.0), 1.0)

        ~s|<circle cx="#{n(x(story, at))}" cy="#{n(y(film, price))}" r="#{n(9 * grow)}" fill="#{@gold}" stroke="#{@field}" stroke-width="3"/>|
      else
        ""
      end
    end)
  end

  # --- the tip -----------------------------------------------------------------

  # The price beside the tip, kept inside the chart.
  defp tag_box(x, y, tag) do
    w = Image.width(tag) + 28
    h = Image.height(tag) + 14
    left = if x + 24 + w > @width - 16, do: x - 24 - w, else: x + 24
    top = min(max(y - h / 2, @chart_y + 8), @floor - h - 8)
    %{x: round(left), y: round(top), w: w, h: h}
  end

  defp pill_svg(box, color, opacity \\ 1.0),
    do:
      ~s|<rect x="#{box.x}" y="#{box.y}" width="#{box.w}" height="#{box.h}" rx="#{div(box.h, 2)}" fill="#{color}" opacity="#{n(opacity)}"/>|

  # A price on the line, written as every figure is. The line's prices are
  # floats, good to 15 significant digits.
  defp dollars(price),
    do:
      Decimal.Context.with(%Decimal.Context{precision: 15}, fn ->
        (price * 1.0) |> Decimal.from_float() |> Decimal.add(0) |> UsdValue.dollars()
      end)

  defp box_text(box, words),
    do:
      {words, box.x + div(box.w - Image.width(words), 2),
       box.y + div(box.h - Image.height(words), 2)}
end
