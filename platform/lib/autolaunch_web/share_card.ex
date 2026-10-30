defmodule AutolaunchWeb.ShareCard do
  @moduledoc """
  The picture and page details a shared auction, token, covered-calls or
  Isolated Exposure to After-hours Stocks link shows on X and other sites.

  The picture is a dark panel inside a tangerine border, with the Autolaunch
  mark and autolaunch.sh along its top and one strip on its left: the token's
  round logo, its name, its ticker line ($TOKEN / STOCK, or $TOKEN for a
  launch paired with no stock token), a pill with the time left in the auction
  or where it stands, its chain and who launched it (`CreatorLabel`), and its
  two figures on rows of their own. An
  auction also draws its clearing price so far as a line under them, and a
  faint Autolaunch mark fills the right. Every word and the line sit in the
  left part of the picture that X's phone view keeps, clear of the corner
  where X lays the site's name. A figure the site does not know yet is left
  out, never shown as zero.

  A covered-call market's or an Isolated Exposure to After-hours Stocks series' picture takes the
  same strip with the stock's mark, the product's name, where it stands, its
  two figures and the stock's price as a line, read from the chain
  (`AutolaunchWeb.ShareVideo.MarketStory`).

  Crawlers read the page without signing in or running scripts, so both the
  picture and the page details come from the stored records or the chain. Names and
  tickers are the creator's own words, so they are drawn as plain text,
  without the symbols the picture's fonts cannot draw, and cut short to fit.
  """
  use Phoenix.Component

  use AutolaunchWeb, :verified_routes

  import AutolaunchWeb.ShareCard.Draw

  alias AutolaunchWeb.Components.{AutolaunchHelpers, CreatorLabel}
  alias AutolaunchWeb.{Paths, PublicDocuments}
  alias AutolaunchWeb.ShareCard.{Cache, MarketPictures}
  alias AutolaunchWeb.ShareVideo.MarketStory
  alias Vix.Vips.{Image, Operation}

  @width 1200
  @height 630

  # X's phone view keeps only the left 660 or so of the picture's 1200 and
  # lays the site's own name over its bottom-left corner (x up to 180, y from
  # 554), so every word sits left of @words_right and above that corner.
  @border 20

  # The top row: the Autolaunch mark and the site's name.
  @mark_x 56
  @mark_y 48
  @mark_h 32

  # The strip, and what sits inside it, from its top.
  @strip_x 48
  @strip_w 584
  @inset 40
  @logo 112
  @logo_x @strip_x + @inset
  @words_x @logo_x + @logo + 28
  @words_right @strip_x + @strip_w - @inset
  @logo_top 24
  @name_top 22
  @ticker_top 90
  @chain_top 152
  @stats_top 214
  @row_h 62
  @line_gap 20
  @line_h 56

  # The strip sits in the panel between the top row and the panel's foot.
  @body_top 104
  @body_bottom @height - @border - 16

  # The large Autolaunch mark on the right of the wide view.
  @art_h 260
  @art_x 700

  @field "#111110"
  @strip "#1c1c1a"
  @edge "#2e2d29"
  @platinum "#e5e3d2"
  @muted "#9a988c"
  @tangerine "#ff5b19"
  @powder "#aecacd"
  @blue "#8fc3ff"

  # The Autolaunch mark: its squares on a 178 x 106 grid.
  @mark_box {31, 46, 178, 106}
  @mark_squares [{31, 46}, {103, 46}, {175, 46}] ++
                  for(y <- [82, 118], x <- [31, 67, 103, 139, 175], do: {x, y})

  @chain_mark_h 28
  @pill_h 42

  @doc """
  The page details for an auction's page: its title, words, address and
  picture, its record in the public API and the structured data about it.
  """
  @spec meta(struct()) :: map()
  def meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) auction on Autolaunch",
      description:
        "Bid on #{auction.token_symbol} on #{chain_name(chain(auction))}. Everyone pays the same price.",
      url: Paths.auction_url(auction),
      image: auction_image_url(auction, DateTime.utc_now()),
      image_alt: "#{auction.title} (#{auction.token_symbol}) auction figures on Autolaunch",
      record: Paths.auction_record_url(auction)
    }
    |> then(&Map.put(&1, :structured_data, PublicDocuments.auction_data(auction, &1)))
  end

  @doc """
  The page details for the covered calls page (`:covered_calls`, by the
  market's symbol) or an Isolated Exposure to After-hours Stocks series (`:exposure`, by its
  address): the page's own title and words, its address and the market's
  picture.
  """
  @spec market_meta(:covered_calls | :exposure, String.t()) :: map()
  def market_meta(kind, subject) do
    [page_title: title, page_description: description] = PublicDocuments.page(page_path(kind))

    %{
      title: "#{title} on Autolaunch",
      description: description,
      url: page_url(kind, subject),
      image: market_image_url(kind, subject, DateTime.utc_now()),
      image_alt: "#{title} on Autolaunch: the stock's price and where the market stands"
    }
  end

  defp page_path(:covered_calls), do: "/covered-calls"
  defp page_path(:exposure), do: "/after-hour-stocks"

  defp page_url(:covered_calls, _symbol), do: url(~p"/covered-calls")
  defp page_url(:exposure, series), do: url(~p"/after-hour-stocks?#{[series: series]}")

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

  @doc "The page details for the page of the token an auction launched, as `meta/1` gives them."
  @spec token_meta(struct(), struct()) :: map()
  def token_meta(auction, token) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) on Autolaunch",
      description:
        "Trade and stake #{auction.token_symbol} on #{chain_name(chain(auction))}. Graduated from an Autolaunch auction.",
      url: Paths.token_url(auction),
      image: token_image_url(auction, DateTime.utc_now()),
      image_alt: "#{auction.title} (#{auction.token_symbol}) token figures on Autolaunch",
      record: Paths.token_record_url(token)
    }
    |> then(&Map.put(&1, :structured_data, PublicDocuments.token_data(auction, &1)))
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
  through the shared Regent metadata head. An auction's or a token's page also
  names its record in the public API, and its structured data describes that
  auction or token rather than the site.
  """
  def head(assigns) do
    share = assigns.share || site_meta(assigns)

    assigns =
      assign(assigns,
        share: share,
        record: share[:record],
        width: @width,
        height: @height,
        markdown: PublicDocuments.markdown?(assigns.path),
        structured_data: share[:structured_data] || PublicDocuments.structured_data()
      )

    ~H"""
    <link :if={@record} rel="alternate" type="application/json" href={@record} />
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
      image_alt:
        "Autolaunch: onchain stocks for agents. DeFi for agents, with Revstake and Memestock."
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

    with {:ok, points} <- Autolaunch.auction_price_points(auction.id, actor: nil),
         {:ok, face} <- launch(auction) do
      draw(face, %{
        badge: {countdown(auction, now), @blue},
        stats: [
          {"Clearing price", money(auction.fdv, rate, auction), @platinum},
          {"Price", money(clearing(auction), rate, auction), @platinum}
        ],
        creator: creator(auction),
        line: line(points, auction.current_clearing_price)
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
    do: Cache.fetch({:token, auction.id}, bucket(now), fn -> draw_token(auction, token) end)

  # While bidding is open the pill counts down to the end; after that it
  # names where the auction stands.
  defp countdown(auction, now) do
    case standing(auction, now) do
      {"Time left", left, _color} -> "Ends in " <> left
      {_label, standing, _color} -> standing
    end
  end

  defp clearing(%{current_clearing_price: price}) when is_binary(price),
    do: Decimal.new(price, max_digits: :infinity)

  defp clearing(_auction), do: nil

  defp draw_token(auction, token) do
    rate = rate(auction)
    price = token.price_quote && Decimal.new(token.price_quote, max_digits: :infinity)

    with {:ok, face} <- launch(auction) do
      draw(face, %{
        badge: {"Graduated", @powder},
        stats: [
          {"FDV", money(token.market_cap, rate, auction), @platinum},
          {"Price", money(price, rate, auction), @platinum}
        ],
        creator: creator(auction),
        line: nil
      })
    end
  end

  @doc """
  Where a covered-call market's (`:covered_calls`, by symbol) or an
  Isolated Exposure to After-hours Stocks series' (`:exposure`, by address) picture is served;
  its price keeps moving, so its address does too.
  """
  @spec market_image_url(:covered_calls | :exposure, String.t(), DateTime.t()) :: String.t()
  def market_image_url(kind, subject, now), do: Paths.market_image_url(kind, subject, bucket(now))

  @doc """
  A covered-call market's or an Isolated Exposure to After-hours Stocks series' picture as PNG
  bytes, from its story (`AutolaunchWeb.ShareVideo.MarketStory`): the stock's
  mark, the product's name, where it stands, its two figures and the stock's
  price as a line under them.
  """
  @spec market_png(:covered_calls | :exposure, String.t(), DateTime.t()) ::
          {:ok, binary()} | {:error, term()}
  def market_png(kind, subject, now),
    do:
      MarketPictures.fetch({kind, subject}, bucket(now), fn ->
        with {:ok, story} <- MarketStory.read(kind, subject, nil),
             {:ok, logo} <- stock_logo(story.ticker, @logo) do
          draw(
            %{
              chain: :base,
              color: @tangerine,
              logo: logo,
              # A product's name is the site's own, so it steps down further
              # before it is cut.
              name: story.title,
              name_sizes: [52, 46, 40, 34, 30],
              ticker: "$" <> story.symbol,
              symbol: story.ticker
            },
            %{
              badge: {story.badge, @blue},
              stats: Enum.map(story.figures, fn {label, value} -> {label, value, @platinum} end),
              creator: nil,
              line: MarketStory.samples(story, 80)
            }
          )
        end
      end)

  # Who launched it, as every list and page names them (`CreatorLabel`).
  defp creator(auction) do
    connections =
      AutolaunchHelpers.connections_for(
        auction,
        AutolaunchHelpers.creator_connections_for([auction])
      )

    case CreatorLabel.name(auction, connections) do
      %{text: text} -> plain(text)
      nil -> nil
    end
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

  # What a launch's picture shows of it: its chain, colour, logo, name and the
  # sizes it steps down through, ticker line and the symbol its initial comes
  # from.
  defp launch(auction) do
    with {:ok, logo} <- logo(auction, @logo),
         do:
           {:ok,
            %{
              chain: chain(auction),
              color: color(auction.image_color),
              logo: logo,
              name: plain(auction.title),
              name_sizes: [52, 46, 40],
              ticker: ticker(auction),
              symbol: auction.token_symbol
            }}
  end

  defp draw(face, card) do
    %{chain: chain, color: color, logo: logo} = face

    with {:ok, words} <- words(face, card),
         layout = layout(words, card.line, chain),
         {:ok, {canvas, _flags}} <-
           Operation.svgload_buffer(svg(chain, color, logo, card, layout)),
         {:ok, picture} <- place(canvas, words, layout, logo) do
      Image.write_to_buffer(picture, ".png")
    end
  end

  # Every line of words drawn once, so the strip can be laid out around their
  # widths.
  defp words(face, card) do
    stats = Enum.reject(card.stats, fn {_label, value, _color} -> is_nil(value) end)
    {badge, badge_color} = card.badge

    with {:ok, site} <- layer("autolaunch.sh", :pixel, 30, @muted),
         {:ok, badge} <- layer(badge, :bold, 24, badge_color),
         {:ok, initial} <- initial(face.symbol),
         {:ok, stats} <- stat_layers(stats) do
      {:ok,
       %{
         site: site,
         ticker: face.ticker,
         badge: {badge, badge_color},
         initial: initial,
         stats: stats,
         name: face.name,
         name_sizes: face.name_sizes,
         creator: card.creator
       }}
    end
  end

  # Each figure sits on its own row, its label on the left and the figure on
  # the right; a long figure steps down in size until it fits beside its label.
  # A figure is never cut short: past its last step it is drawn at the size
  # that fits.
  defp stat_layers(stats) do
    Enum.reduce_while(Enum.reverse(stats), {:ok, []}, fn {label, value, color}, {:ok, done} ->
      with {:ok, label} <- layer(label, :regular, 28, @muted),
           max = @words_right - @logo_x - Image.width(label) - 24,
           {:ok, value} <- figure(value, color, max, [40, 36, 32]) do
        {:cont, {:ok, [{label, value} | done]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # Where the strip goes: tall enough for the figures and, for an auction, the
  # price line under them, and centred in the panel under the top row.
  defp layout(words, line, chain) do
    stats_bottom = @stats_top + length(words.stats) * @row_h
    strip_h = if line, do: stats_bottom + @line_gap + @line_h + 28, else: stats_bottom + 24
    {badge, _color} = words.badge

    %{
      top: @body_top + div(@body_bottom - @body_top - strip_h, 2),
      strip_h: strip_h,
      rows: length(words.stats),
      line_top: stats_bottom + @line_gap,
      badge_w: Image.width(badge) + 36,
      chain_w: mark_width(chain, @chain_mark_h)
    }
  end

  # The name and the ticker share the room right of the logo.
  defp place(canvas, words, layout, logo) do
    top = layout.top

    with {:ok, name} <- name(words.name, words.name_sizes, @words_right - @words_x),
         {:ok, ticker} <-
           sized(words.ticker, :regular, @muted, @words_right - @words_x, [34, 30, 28]),
         {:ok, creator} <- creator_words(words.creator, layout) do
      {badge, _color} = words.badge

      [
        {words.site, {site_x(), @mark_y + div(@mark_h - Image.height(words.site), 2)}},
        {ticker, {@words_x, top + @ticker_top}},
        {badge, {badge_x(), top + @chain_top + div(@pill_h - Image.height(badge), 2)}}
      ]
      |> Kernel.++(name_at(name, top))
      |> Kernel.++(creator_at(creator, top))
      |> Kernel.++(initial_at(logo, words.initial, top))
      |> Kernel.++(stats_at(words.stats, top))
      |> composite(canvas)
    end
  end

  defp stats_at(stats, top) do
    stats
    |> Enum.with_index()
    |> Enum.flat_map(fn {{label, value}, index} ->
      middle = top + @stats_top + index * @row_h + div(@row_h, 2)

      [
        {label, {@logo_x, middle - div(Image.height(label), 2)}},
        {value, {@words_right - Image.width(value), middle - div(Image.height(value), 2)}}
      ]
    end)
  end

  # A name with nothing the fonts can draw is left out; the ticker still names
  # the token.
  defp name("", _sizes, _max), do: {:ok, nil}
  defp name(words, sizes, max), do: sized(words, :bold, @platinum, max, sizes)

  # The words step down in size until they fit, and are cut short at the
  # smallest.
  defp figure(value, color, max, [size | smaller]) do
    with {:ok, layer} <- layer(value, :bold, size, color) do
      cond do
        Image.width(layer) <= max -> {:ok, layer}
        smaller != [] -> figure(value, color, max, smaller)
        true -> figure(value, color, max, [div(size * max, Image.width(layer))])
      end
    end
  end

  defp sized(words, weight, color, max, [size]), do: fit(words, weight, size, color, max)

  defp sized(words, weight, color, max, [size | smaller]) do
    with {:ok, layer} <- layer(words, weight, size, color) do
      if Image.width(layer) <= max,
        do: {:ok, layer},
        else: sized(words, weight, color, max, smaller)
    end
  end

  # Who launched it ends the chain's row, in the room right of the badge and
  # the chain's mark.
  defp creator_words(nil, _layout), do: {:ok, nil}

  defp creator_words(creator, layout) do
    left = badge_x() + layout.badge_w + 6 + layout.chain_w + 20
    sized("by " <> creator, :regular, @muted, @words_right - left, [28, 26, 24])
  end

  defp creator_at(nil, _top), do: []

  defp creator_at(creator, top),
    do: [
      {creator,
       {@words_right - Image.width(creator),
        top + @chain_top + div(@pill_h - Image.height(creator), 2)}}
    ]

  defp name_at(nil, _top), do: []
  defp name_at(name, top), do: [{name, {@words_x, top + @name_top}}]

  # The ticker's first letter stands in the logo's place when there is no
  # logo; the SVG draws the logo itself when there is one.
  defp initial_at(nil, %Image{} = initial, top),
    do: [
      {initial,
       {@logo_x + div(@logo - Image.width(initial), 2),
        top + @logo_top + div(@logo - Image.height(initial), 2)}}
    ]

  defp initial_at(_logo, _initial, _top), do: []

  defp composite(parts, canvas) do
    Enum.reduce_while(parts, {:ok, canvas}, fn {layer, {x, y}}, {:ok, picture} ->
      case Operation.composite2(picture, layer, :VIPS_BLEND_MODE_OVER, x: x, y: y) do
        {:ok, picture} -> {:cont, {:ok, picture}}
        error -> {:halt, error}
      end
    end)
  end

  # The chain's mark and the badge sit on one row under the ticker, from the
  # logo's left edge.
  defp badge_x, do: @logo_x + 18

  # The site's name follows the mark along the top row.
  defp site_x, do: @mark_x + mark_w(@mark_h) + 20

  defp svg(chain, color, logo, card, layout) do
    {_badge, badge_color} = card.badge
    top = layout.top
    chain_y = top + @chain_top

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">
      <defs>
        <radialGradient id="glow" cx="#{(@logo_x + div(@logo, 2)) / @width}" cy="#{(top + @logo_top + div(@logo, 2)) / @height}" r="0.6">
          <stop offset="0" stop-color="#{color}" stop-opacity="0.14"/>
          <stop offset="1" stop-color="#{color}" stop-opacity="0"/>
        </radialGradient>
        <linearGradient id="under" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#{@tangerine}" stop-opacity="0.28"/>
          <stop offset="1" stop-color="#{@tangerine}" stop-opacity="0"/>
        </linearGradient>
        <clipPath id="round"><circle cx="#{@logo_x + div(@logo, 2)}" cy="#{top + @logo_top + div(@logo, 2)}" r="#{div(@logo, 2)}"/></clipPath>
      </defs>
      <rect width="#{@width}" height="#{@height}" fill="#{@tangerine}"/>
      <rect x="#{@border}" y="#{@border}" width="#{@width - 2 * @border}" height="#{@height - 2 * @border}" rx="36" fill="#{@field}"/>
      <rect x="#{@border}" y="#{@border}" width="#{@width - 2 * @border}" height="#{@height - 2 * @border}" rx="36" fill="url(#glow)"/>
      #{mark_svg(@mark_x, @mark_y, @mark_h, 1)}
      #{mark_svg(@art_x, div(@height - @art_h, 2), @art_h, 0.12)}
      <rect x="#{@strip_x}" y="#{top}" width="#{@strip_w}" height="#{layout.strip_h}" rx="40"
        fill="#{@strip}" stroke="#{@edge}" stroke-width="2"/>
      #{logo_svg(logo, color, top + @logo_top)}
      #{badge_svg(badge_color, layout.badge_w, chain_y)}
      <image x="#{badge_x() + layout.badge_w + 6}" y="#{chain_y + div(@pill_h - @chain_mark_h, 2)}" width="#{mark_width(chain, @chain_mark_h)}"
        height="#{@chain_mark_h}" href="data:image/svg+xml;base64,#{Base.encode64(chain_mark(chain))}"/>
      #{rules_svg(layout.rows, top)}
      #{line_svg(card.line, top + layout.line_top)}
    </svg>
    """
  end

  # The Autolaunch mark `height` tall with its top left at `x`, `y`.
  defp mark_svg(x, y, height, opacity) do
    {left, top, _width, box_h} = @mark_box
    scale = height / box_h

    squares =
      Enum.map_join(@mark_squares, fn {sx, sy} ->
        ~s|<rect x="#{sx}" y="#{sy}" width="34" height="34"/>|
      end)

    ~s|<g fill="#{@tangerine}" fill-opacity="#{opacity}" transform="translate(#{x} #{y}) scale(#{scale}) translate(#{-left} #{-top})">#{squares}</g>|
  end

  defp mark_w(height) do
    {_left, _top, width, box_h} = @mark_box
    round(height * width / box_h)
  end

  # A thin rule above each figure's row.
  defp rules_svg(rows, top) do
    Enum.map_join(0..(rows - 1)//1, fn index ->
      y = top + @stats_top + index * @row_h

      ~s|<rect x="#{@logo_x}" y="#{y}" width="#{@words_right - @logo_x}" height="2" fill="#{@edge}"/>|
    end)
  end

  defp logo_svg(nil, color, y),
    do:
      ~s|<circle cx="#{@logo_x + div(@logo, 2)}" cy="#{y + div(@logo, 2)}" r="#{div(@logo, 2)}" fill="#{color}"/>|

  defp logo_svg(png, _color, y),
    do:
      ~s|<image x="#{@logo_x}" y="#{y}" width="#{@logo}" height="#{@logo}" clip-path="url(#round)" href="data:image/png;base64,#{Base.encode64(png)}"/>|

  defp badge_svg(color, width, y),
    do:
      ~s|<rect x="#{badge_x() - 18}" y="#{y}" width="#{width}" height="#{@pill_h}" rx="#{div(@pill_h, 2)}" fill="none" stroke="#{color}" stroke-width="2"/>|

  defp line_svg(nil, _top), do: ""

  # The clearing price across the strip under the figures, shaded down to the
  # line's foot.
  defp line_svg(prices, top) do
    {low, high} = Enum.min_max(prices)
    bottom = top + @line_h
    left = @logo_x
    width = @words_right - @logo_x
    step = width / (length(prices) - 1)

    points =
      prices
      |> Enum.with_index()
      |> Enum.map(fn {price, index} ->
        y =
          if high == low,
            do: top + @line_h / 2,
            else: top + @line_h * (high - price) / (high - low)

        {left + index * step, y}
      end)

    path =
      Enum.map_join(points, " ", fn {px, py} ->
        "#{Float.round(px * 1.0, 1)},#{Float.round(py * 1.0, 1)}"
      end)

    """
    <polygon points="#{left},#{bottom} #{path} #{left + width},#{bottom}" fill="url(#under)"/>
    <polyline points="#{path}" fill="none" stroke="#{@tangerine}" stroke-width="4"
      stroke-linejoin="round" stroke-linecap="round"/>
    """
  end

  defp initial(symbol) do
    case symbol |> plain() |> String.first() do
      nil -> {:ok, nil}
      letter -> layer(String.upcase(letter), :pixel, 56, @field)
    end
  end
end
