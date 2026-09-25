defmodule AutolaunchWeb.ShareCard do
  @moduledoc """
  The picture and page details a shared auction or token link shows on X and
  other sites.

  The picture is one strip on a dark field, like X's own token cards: the
  token's round logo, its name, $TICKER and chain, and on the right its FDV
  with the time left in the auction or, once launched, its price. An auction
  also draws its clearing price so far as a thin line. A figure the site does
  not know yet is left out, never shown as zero.

  Crawlers read the page without signing in or running scripts, so both the
  picture and the page details come from the stored records. Names and
  tickers are the creator's own words, so they are drawn as plain text,
  without the symbols the picture's fonts cannot draw, and cut short to fit.
  """
  use Phoenix.Component

  use AutolaunchWeb, :verified_routes

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.StoredImage
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{Paths, TokenDisplay, UsdValue}
  alias Vix.Vips.{Image, Operation}

  @width 1200
  @height 630

  # The strip, and what sits inside it.
  @strip_x 48
  @strip_y 170
  @strip_w @width - 2 * @strip_x
  @strip_h 300
  @inset 44
  @logo 184
  @logo_x @strip_x + @inset
  @logo_y @strip_y + div(@strip_h - @logo, 2)
  @words_x @logo_x + @logo + 40
  @right @strip_x + @strip_w - @inset
  @line_w 230
  @line_h 96
  @gap 48

  @field "#111110"
  @strip "#1c1c1a"
  @edge "#2e2d29"
  @platinum "#e5e3d2"
  @muted "#9a988c"
  @tangerine "#ff5b19"
  @powder "#aecacd"

  @chain_mark_h 28
  @pill_h 42
  @chains %{
    base: %{name: "Base", mark_w: round(@chain_mark_h * 1280 / 323.84)},
    robinhood: %{name: "Robinhood Chain", mark_w: round(@chain_mark_h * 1576 / 207)}
  }

  @doc "The page details for an auction's page: its title, words, address and picture."
  @spec meta(struct()) :: map()
  def meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) auction on Autolaunch",
      description:
        "Bid on #{auction.token_symbol} on #{@chains[chain(auction)].name}. Everyone pays the same price.",
      url: Paths.auction_url(auction),
      image: auction_image_url(auction, DateTime.utc_now()),
      image_alt: "#{auction.title} (#{auction.token_symbol}) auction figures on Autolaunch"
    }
  end

  @doc "The page details for the page of the token an auction launched."
  @spec token_meta(struct()) :: map()
  def token_meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) on Autolaunch",
      description:
        "Trade and stake #{auction.token_symbol} on #{@chains[chain(auction)].name}. Launched through an Autolaunch auction.",
      url: Paths.token_url(auction),
      image: token_image_url(auction, DateTime.utc_now()),
      image_alt: "#{auction.title} (#{auction.token_symbol}) token figures on Autolaunch"
    }
  end

  @doc """
  Where an auction's picture is served, as its figures stand at `now`. The
  address moves on every fifteen minutes while the auction can still change,
  so a site that keeps pictures by address fetches the new figures, and stays
  put once the auction has finished.
  """
  @spec auction_image_url(struct(), DateTime.t()) :: String.t()
  def auction_image_url(auction, now),
    do: Paths.auction_image_url(auction, auction_version(auction, now))

  @doc "Where a token's picture is served; its price keeps moving, so its address does too."
  @spec token_image_url(struct(), DateTime.t()) :: String.t()
  def token_image_url(auction, now), do: Paths.token_image_url(auction, bucket(now))

  defp auction_version(%{state: state}, _now) when state in [:graduated, :failed],
    do: Atom.to_string(state)

  defp auction_version(_auction, now), do: bucket(now)

  defp bucket(now), do: now |> DateTime.to_unix() |> div(900) |> Integer.to_string()

  attr :share, :map, default: nil, doc: "a page's details, or nil for the site's own"
  attr :page_title, :string, default: nil

  @doc "The Open Graph and X card tags for the page."
  def tags(%{share: nil} = assigns) do
    ~H"""
    <meta property="og:title" content={@page_title || "Autolaunch"} />
    <meta
      property="og:description"
      content="Autolaunch is for backing long-term agents. Raise early funds through an auction. No early snipers here. If you are in the auction, you are early."
    />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Autolaunch" />
    <meta property="og:image" content={url(~p"/images/og-image.png")} />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta
      property="og:image:alt"
      content="agents: autolaunch your token. Auctions for agents, with Revstake and Memestake."
    />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:image" content={url(~p"/images/og-image.png")} />
    """
  end

  def tags(assigns) do
    ~H"""
    <meta property="og:title" content={@share.title} />
    <meta property="og:description" content={@share.description} />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Autolaunch" />
    <meta property="og:url" content={@share.url} />
    <meta property="og:image" content={@share.image} />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content={@share.image_alt} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content={@share.title} />
    <meta name="twitter:description" content={@share.description} />
    <meta name="twitter:image" content={@share.image} />
    """
  end

  @doc """
  An auction's picture as PNG bytes, with its figures as read at `now`: its
  FDV, the time left or where it stands, and its clearing price so far.
  """
  @spec auction_png(struct(), DateTime.t()) :: {:ok, binary()} | {:error, term()}
  def auction_png(auction, now) do
    rate = rate(auction)

    with {:ok, points} <- Autolaunch.auction_price_points(auction.id, actor: nil) do
      draw(auction, %{
        badge: {"Auction", @tangerine},
        stats: [{"FDV", money(auction.fdv, rate, auction), @platinum}, standing(auction, now)],
        line: line(points, auction.current_clearing_price),
        now: now
      })
    end
  end

  @doc """
  The picture of the token an auction launched, as PNG bytes: its FDV at its
  last price and that price per token. `token` carries `market_cap`, which
  is the FDV: the price times the whole supply.
  """
  @spec token_png(struct(), struct(), DateTime.t()) :: {:ok, binary()} | {:error, term()}
  def token_png(auction, token, now) do
    rate = rate(auction)
    price = token.price_quote && Decimal.new(token.price_quote, max_digits: :infinity)

    draw(auction, %{
      badge: {"Launched", @powder},
      stats: [
        {"FDV", money(token.market_cap, rate, auction), @platinum},
        {"Price", money(price, rate, auction), @platinum}
      ],
      line: nil,
      now: now
    })
  end

  defp chain(auction),
    do: if(RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base)

  # No dollar value is shown for a test network's coins.
  defp rate(auction) do
    case chain(auction) do
      :robinhood ->
        if RobinhoodLab.test_chain?(),
          do: nil,
          else: UsdValue.stock_rate(MarketData.prices(:robinhood), auction.quote_token_symbol)

      :base ->
        if Lab.test_chain?(), do: nil, else: UsdValue.rate(auction)
    end
  end

  # How long bidding has left, or where the auction stands once it cannot
  # be told.
  defp standing(%{state: :active, estimated_end_at: %DateTime{} = ends} = auction, now) do
    case DateTime.diff(ends, now) do
      left when left > 0 -> {"Time left", duration(left), @tangerine}
      _over -> {"Status", MarketCard.state_label(auction.state), @platinum}
    end
  end

  defp standing(auction, _now), do: {"Status", MarketCard.state_label(auction.state), @platinum}

  defp duration(seconds) when seconds >= 86_400,
    do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"

  defp duration(seconds) when seconds >= 3_600,
    do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  defp duration(seconds), do: "#{max(div(seconds, 60), 1)}m"

  # Dollars at the currency's market price, or the currency itself where no
  # price is known.
  defp money(nil, _rate, _auction), do: nil
  defp money(amount, %Decimal{} = rate, _auction), do: "$" <> short(Decimal.mult(amount, rate))
  defp money(amount, _rate, auction), do: short(amount) <> " " <> auction.quote_token_symbol

  @scales [{1_000_000_000, "B"}, {1_000_000, "M"}, {1_000, "K"}]

  defp short(amount) do
    case Enum.find(@scales, fn {scale, _suffix} -> Decimal.gte?(amount, scale) end) do
      {scale, suffix} -> amount |> Decimal.div(scale) |> figure() |> Kernel.<>(suffix)
      nil -> figure(amount)
    end
  end

  # Three significant digits, with a long run of zeros after the point counted.
  defp figure(%Decimal{coef: coef, exp: exp} = amount) do
    places = max(3 - length(Integer.digits(coef)) - exp, 0)

    amount
    |> Decimal.round(places)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
    |> TokenDisplay.zeros()
  end

  # The clearing price at every recorded change, then as it stands now; no
  # line until the price has at least two points.
  defp line(points, current) do
    prices = Enum.map(points, &Decimal.to_float(&1.clearing_price))

    case if(current, do: prices ++ [price(current)], else: prices) do
      [_first, _second | _rest] = prices -> prices
      _fewer -> nil
    end
  end

  defp price(price), do: price |> Decimal.new(max_digits: :infinity) |> Decimal.to_float()

  defp draw(auction, card) do
    chain = chain(auction)
    color = color(auction.image_color)

    with {:ok, words} <- words(auction, card),
         {:ok, logo} <- logo(auction),
         layout = layout(words, card.line),
         {:ok, {canvas, _flags}} <-
           Operation.svgload_buffer(svg(chain, color, logo, card, layout)),
         {:ok, picture} <- place(canvas, words, layout, logo) do
      Image.write_to_buffer(picture, ".png")
    end
  end

  # A stored colour is drawn only in its one shape, `#rrggbb`.
  defp color(color) when is_binary(color) do
    if Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, color), do: color, else: @tangerine
  end

  defp color(_color), do: @tangerine

  # Every line of words drawn once, so the strip can be laid out around their
  # widths.
  defp words(auction, card) do
    stats = Enum.reject(card.stats, fn {_label, value, _color} -> is_nil(value) end)
    {badge, badge_color} = card.badge

    with {:ok, wordmark} <- layer("Autolaunch", :pixel, 36, @platinum),
         {:ok, stamp} <-
           layer(
             "As of #{Calendar.strftime(card.now, "%b %-d, %H:%M")} UTC",
             :regular,
             24,
             @muted
           ),
         {:ok, ticker} <- fit("$" <> plain(auction.token_symbol), :regular, 40, @muted, 440),
         {:ok, badge} <- layer(badge, :bold, 24, badge_color),
         {:ok, initial} <- initial(auction.token_symbol),
         {:ok, stats} <- stat_layers(stats) do
      {:ok,
       %{
         wordmark: wordmark,
         stamp: stamp,
         ticker: ticker,
         badge: {badge, badge_color},
         initial: initial,
         stats: stats,
         name: plain(auction.title)
       }}
    end
  end

  defp stat_layers(stats) do
    Enum.reduce_while(Enum.reverse(stats), {:ok, []}, fn {label, value, color}, {:ok, done} ->
      with {:ok, label} <- layer(label, :regular, 28, @muted),
           {:ok, value} <- layer(value, :bold, 54, color) do
        {:cont, {:ok, [{label, value} | done]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Where each part goes: the figures hang from the strip's right edge, the
  # price line sits just left of them, and the name takes what room is left.
  defp layout(words, line) do
    stats_w = words.stats |> Enum.flat_map(&Tuple.to_list/1) |> Enum.map(&Image.width/1)
    stats_x = @right - Enum.max([0 | stats_w])
    line_x = stats_x - @gap - @line_w
    name_edge = if line, do: line_x - @gap, else: stats_x - @gap

    {badge, _color} = words.badge

    %{
      stats_x: stats_x,
      line_x: line_x,
      name_w: name_edge - @words_x,
      badge_w: Image.width(badge) + 36
    }
  end

  defp place(canvas, words, layout, logo) do
    with {:ok, name} <- name(words.name, layout.name_w) do
      {badge, _color} = words.badge

      [
        {words.wordmark, {@strip_x, 64}},
        {words.stamp, {@width - @strip_x - Image.width(words.stamp), @height - 70}},
        {words.ticker, {@words_x, @strip_y + 128}},
        {badge, {badge_x(), chain_row_y() + div(@pill_h - Image.height(badge), 2)}}
      ]
      |> Kernel.++(name_at(name))
      |> Kernel.++(initial_at(logo, words.initial))
      |> Kernel.++(stats_at(words.stats))
      |> composite(canvas)
    end
  end

  defp stats_at(stats) do
    stats
    |> Enum.with_index()
    |> Enum.flat_map(fn {{label, value}, index} ->
      top = @strip_y + 36 + index * 124

      [
        {label, {@right - Image.width(label), top}},
        {value, {@right - Image.width(value), top + 34}}
      ]
    end)
  end

  # A long name steps down in size before it is cut short. A name with
  # nothing the fonts can draw is left out; the ticker still names the token.
  defp name("", _max), do: {:ok, nil}

  defp name(words, max), do: name(words, max, [64, 56, 48])

  defp name(words, max, [size]), do: fit(words, :bold, size, @platinum, max)

  defp name(words, max, [size | smaller]) do
    with {:ok, layer} <- layer(words, :bold, size, @platinum) do
      if Image.width(layer) <= max, do: {:ok, layer}, else: name(words, max, smaller)
    end
  end

  defp name_at(nil), do: []
  defp name_at(name), do: [{name, {@words_x, @strip_y + 44}}]

  # The ticker's first letter stands in the logo's place when there is no
  # logo; the SVG draws the logo itself when there is one.
  defp initial_at(nil, %Image{} = initial),
    do: [
      {initial,
       {@logo_x + div(@logo - Image.width(initial), 2),
        @logo_y + div(@logo - Image.height(initial), 2)}}
    ]

  defp initial_at(_logo, _initial), do: []

  defp composite(parts, canvas) do
    Enum.reduce_while(parts, {:ok, canvas}, fn {layer, {x, y}}, {:ok, picture} ->
      case Operation.composite2(picture, layer, :VIPS_BLEND_MODE_OVER, x: x, y: y) do
        {:ok, picture} -> {:cont, {:ok, picture}}
        error -> {:halt, error}
      end
    end)
  end

  # The chain's mark and the badge sit on one row under the ticker.
  defp chain_row_y, do: @strip_y + 204
  defp badge_x, do: @words_x + 18

  defp svg(chain, color, logo, card, layout) do
    {_badge, badge_color} = card.badge

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">
      <defs>
        <radialGradient id="glow" cx="#{(@logo_x + div(@logo, 2)) / @width}" cy="0.5" r="0.6">
          <stop offset="0" stop-color="#{color}" stop-opacity="0.14"/>
          <stop offset="1" stop-color="#{color}" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="under" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@tangerine}" stop-opacity="0.28"/>
          <stop offset="1" stop-color="#{@tangerine}" stop-opacity="0"/>
        </linearGradient>
        <clipPath id="round"><circle cx="#{@logo_x + div(@logo, 2)}" cy="#{@logo_y + div(@logo, 2)}" r="#{div(@logo, 2)}"/></clipPath>
      </defs>
      <rect width="#{@width}" height="#{@height}" fill="#{@field}"/>
      <rect width="#{@width}" height="#{@height}" fill="url(#glow)"/>
      <rect x="#{@strip_x}" y="#{@strip_y}" width="#{@strip_w}" height="#{@strip_h}" rx="40"
        fill="#{@strip}" stroke="#{@edge}" stroke-width="2"/>
      #{logo_svg(logo, color)}
      #{badge_svg(badge_color, layout.badge_w)}
      <image x="#{badge_x() + layout.badge_w + 6}" y="#{chain_row_y() + div(@pill_h - @chain_mark_h, 2)}" width="#{@chains[chain].mark_w}"
        height="#{@chain_mark_h}" href="data:image/svg+xml;base64,#{Base.encode64(chain_mark(chain))}"/>
      #{line_svg(card.line, layout.line_x)}
    </svg>
    """
  end

  defp logo_svg(nil, color),
    do:
      ~s|<circle cx="#{@logo_x + div(@logo, 2)}" cy="#{@logo_y + div(@logo, 2)}" r="#{div(@logo, 2)}" fill="#{color}"/>|

  defp logo_svg(png, _color),
    do:
      ~s|<image x="#{@logo_x}" y="#{@logo_y}" width="#{@logo}" height="#{@logo}" clip-path="url(#round)" href="data:image/png;base64,#{Base.encode64(png)}"/>|

  defp badge_svg(color, width),
    do:
      ~s|<rect x="#{badge_x() - 18}" y="#{chain_row_y()}" width="#{width}" height="#{@pill_h}" rx="#{div(@pill_h, 2)}" fill="none" stroke="#{color}" stroke-width="2"/>|

  defp line_svg(nil, _x), do: ""

  # The shading under the line stops just above the chain row, so a long chain
  # name never runs under it.
  defp line_svg(prices, x) do
    {low, high} = Enum.min_max(prices)
    bottom = chain_row_y() - 12
    top = bottom - 24 - @line_h
    step = @line_w / (length(prices) - 1)

    points =
      prices
      |> Enum.with_index()
      |> Enum.map(fn {price, index} ->
        y =
          if high == low,
            do: top + @line_h / 2,
            else: top + @line_h * (high - price) / (high - low)

        {x + index * step, y}
      end)

    path =
      Enum.map_join(points, " ", fn {px, py} ->
        "#{Float.round(px * 1.0, 1)},#{Float.round(py * 1.0, 1)}"
      end)

    """
    <polygon points="#{x},#{bottom} #{path} #{x + @line_w},#{bottom}" fill="url(#under)"/>
    <polyline points="#{path}" fill="none" stroke="#{@tangerine}" stroke-width="4"
      stroke-linejoin="round" stroke-linecap="round"/>
    """
  end

  defp logo(auction) do
    case StoredImage.bytes(auction.image) do
      {:ok, bytes} ->
        with {:ok, image} <-
               Operation.thumbnail_buffer(bytes, @logo,
                 height: @logo,
                 crop: :VIPS_INTERESTING_CENTRE
               ),
             do: Image.write_to_buffer(image, ".png")

      :error ->
        {:ok, nil}
    end
  end

  # A mark shipped with the site; the chain is :base or :robinhood, never a request's input.
  # sobelow_skip ["Traversal.FileModule"]
  defp chain_mark(chain), do: File.read!(share_file("#{chain}.svg"))

  # A creator's words without control characters or the pictographs the
  # picture's fonts cannot draw, on one line.
  defp plain(words) do
    words
    |> String.replace(
      ~r/[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{So}\x{FE00}-\x{FE0F}\x{1F3FB}-\x{1F3FF}]/u,
      ""
    )
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp initial(symbol) do
    case symbol |> plain() |> String.first() do
      nil -> {:ok, nil}
      letter -> layer(String.upcase(letter), :pixel, 84, @field)
    end
  end

  # The words on one line no wider than `max`, cut short with an ellipsis
  # where they run over.
  defp fit(words, weight, size, color, max) do
    with {:ok, layer} <- layer(words, weight, size, color) do
      if Image.width(layer) <= max or String.length(words) <= 1,
        do: {:ok, layer},
        else: shorter(words, weight, size, color, max, Image.width(layer))
    end
  end

  defp shorter(words, weight, size, color, max, width) do
    graphemes = String.graphemes(words)
    keep = min(floor(length(graphemes) * max / width), length(graphemes) - 1)
    cut(graphemes, keep, weight, size, color, max)
  end

  defp cut(graphemes, keep, weight, size, color, max) do
    words = (graphemes |> Enum.take(max(keep, 1)) |> Enum.join() |> String.trim_trailing()) <> "…"

    with {:ok, layer} <- layer(words, weight, size, color) do
      if Image.width(layer) <= max or keep <= 1,
        do: {:ok, layer},
        else: cut(graphemes, keep - 1, weight, size, color, max)
    end
  end

  defp layer(words, weight, size, color) do
    {face, file} = font(weight)

    with {:ok, {layer, _flags}} <-
           Operation.text(~s|<span foreground="#{color}">#{escape(words)}</span>|,
             font: "#{face} #{size}",
             fontfile: file,
             rgba: true,
             dpi: 72
           ),
         do: {:ok, layer}
  end

  defp font(:bold), do: {"Geist SemiBold", share_file("Geist-SemiBold.ttf")}
  defp font(:regular), do: {"Geist", share_file("Geist-Regular.ttf")}
  defp font(:pixel), do: {"Geist Pixel Square", share_file("GeistPixel-Square.ttf")}

  defp share_file(name), do: Application.app_dir(:autolaunch, ["priv", "share_card", name])

  defp escape(words), do: words |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
