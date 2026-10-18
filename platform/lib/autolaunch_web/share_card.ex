defmodule AutolaunchWeb.ShareCard do
  @moduledoc """
  The picture and page details a shared auction or token link shows on X and
  other sites.

  The picture is one strip on a dark field, like X's own token cards: the
  token's round logo, its name, its ticker line ($TOKEN / STOCK, or $TOKEN for
  a launch paired with no stock token) and chain, and on the right its FDV
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

  import AutolaunchWeb.ShareCard.Draw

  alias AutolaunchWeb.{Paths, PublicDocuments}
  alias AutolaunchWeb.ShareCard.Cache
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

  @doc "The page details for an auction's page: its title, words, address and picture."
  @spec meta(struct()) :: map()
  def meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) auction on Autolaunch",
      description:
        "Bid on #{auction.token_symbol} on #{chain_name(chain(auction))}. Everyone pays the same price.",
      url: Paths.auction_url(auction),
      image: auction_image_url(auction, DateTime.utc_now()),
      image_alt: "#{auction.title} (#{auction.token_symbol}) auction figures on Autolaunch"
    }
  end

  @doc "The page details for How Autolaunch works."
  @spec how_it_works_meta() :: map()
  def how_it_works_meta do
    %{
      title: "How Autolaunch works",
      description:
        "Supply, trading fees and staking rewards for every Autolaunch token, Revstake and Memestock.",
      url: url(~p"/how-it-works"),
      image: url(~p"/images/og-how-it-works.png"),
      image_alt:
        "How Autolaunch works: Revstake has 100 billion tokens and a 48 hour auction; Memestock has 1 billion tokens and a 24 hour auction."
    }
  end

  @doc "The page details for the page of the token an auction launched."
  @spec token_meta(struct()) :: map()
  def token_meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) on Autolaunch",
      description:
        "Trade and stake #{auction.token_symbol} on #{chain_name(chain(auction))}. Graduated from an Autolaunch auction.",
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
  attr :title, :string, required: true, doc: "the page's full browser title"
  attr :description, :string, required: true
  attr :path, :string, required: true, doc: "the address the page is known by, without its query"

  @doc """
  The page's description, canonical address, share card and structured data,
  through the shared Regent metadata head.
  """
  def head(assigns) do
    share = assigns.share || site_meta(assigns)

    assigns =
      assign(assigns,
        share: share,
        width: @width,
        height: @height,
        markdown: PublicDocuments.markdown?(assigns.path),
        structured_data: PublicDocuments.structured_data()
      )

    ~H"""
    <Regent.AgentMetadata.head
      title={@share.title}
      description={@share.description}
      canonical={@share.url}
      site_name="Autolaunch"
      site_type="app"
      image={@share.image}
      image_width={@width}
      image_height={@height}
      image_alt={@share.image_alt}
      twitter_site="@regents_sh"
      markdown={@markdown}
      agent_guide={url(~p"/llms.txt")}
      sitemap={url(~p"/sitemap.xml")}
      service_description={url(~p"/openapi.json")}
      structured_data={@structured_data}
    />
    """
  end

  defp site_meta(assigns) do
    %{
      title: assigns.title,
      description: assigns.description,
      url: PublicDocuments.url(assigns.path),
      image: url(~p"/images/og-image.png"),
      image_alt: "where agents launch. Auctions for agents, with Revstake and Memestock."
    }
  end

  @doc """
  An auction's picture as PNG bytes, with its figures as read at `now`: its
  FDV, the time left or where it stands, and its clearing price so far. The
  picture is drawn once per version of its address and kept (`Cache`).
  """
  @spec auction_png(struct(), DateTime.t()) :: {:ok, binary()} | {:error, term()}
  def auction_png(auction, now),
    do:
      Cache.fetch({:auction, auction.id}, auction_version(auction, now), fn ->
        draw_auction(auction, now)
      end)

  defp draw_auction(auction, now) do
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
  def token_png(auction, token, now),
    do: Cache.fetch({:token, auction.id}, bucket(now), fn -> draw_token(auction, token, now) end)

  defp draw_token(auction, token, now) do
    rate = rate(auction)
    price = token.price_quote && Decimal.new(token.price_quote, max_digits: :infinity)

    draw(auction, %{
      badge: {"Graduated", @powder},
      stats: [
        {"FDV", money(token.market_cap, rate, auction), @platinum},
        {"Price", money(price, rate, auction), @platinum}
      ],
      line: nil,
      now: now
    })
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
         {:ok, logo} <- logo(auction, @logo),
         layout = layout(words, card.line),
         {:ok, {canvas, _flags}} <-
           Operation.svgload_buffer(svg(chain, color, logo, card, layout)),
         {:ok, picture} <- place(canvas, words, layout, logo) do
      Image.write_to_buffer(picture, ".png")
    end
  end

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
         {:ok, ticker} <- fit(ticker(auction), :regular, 40, @muted, 440),
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
      <image x="#{badge_x() + layout.badge_w + 6}" y="#{chain_row_y() + div(@pill_h - @chain_mark_h, 2)}" width="#{mark_width(chain, @chain_mark_h)}"
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

  defp initial(symbol) do
    case symbol |> plain() |> String.first() do
      nil -> {:ok, nil}
      letter -> layer(String.upcase(letter), :pixel, 84, @field)
    end
  end
end
