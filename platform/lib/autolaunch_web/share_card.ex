defmodule AutolaunchWeb.ShareCard do
  @moduledoc """
  The picture and page details a shared auction link shows on X and other
  sites: the token's image, name, ticker and chain, then its FDV at the floor
  price, its bid volume, its progress to the minimum raise and its status, as
  read when the picture was drawn. A figure the site does not know yet is left
  out, never shown as zero.

  Crawlers read the page without signing in or running scripts, so both the
  picture and the page details come from the stored auction.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: AutolaunchWeb.Endpoint,
    router: AutolaunchWeb.Router,
    statics: AutolaunchWeb.static_paths()

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.StoredImage
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Vix.Vips.{Image, Operation}

  @width 1200
  @height 630
  @avatar 240
  @margin 64
  @logo_height 34
  @left @margin + @avatar + 40
  @column div(@width - 2 * @margin, 3)

  @chains %{
    base: %{name: "Base", color: "#0052ff", logo_width: round(34 * 1280 / 323.84)},
    robinhood: %{name: "Robinhood Chain", color: "#00c805", logo_width: round(34 * 1576 / 207)}
  }

  @doc "The page details for an auction's page: its title, words and picture."
  @spec meta(struct()) :: map()
  def meta(auction) do
    %{
      title: "#{auction.title} (#{auction.token_symbol}) auction on Autolaunch",
      description:
        "Bid on #{auction.token_symbol} on #{@chains[chain(auction)].name}. Everyone pays the same price.",
      image: image_url(auction),
      image_alt: "#{auction.title} (#{auction.token_symbol}) auction figures on Autolaunch"
    }
  end

  @doc "Where an auction's picture is served."
  @spec image_url(struct()) :: String.t()
  def image_url(auction) do
    case chain(auction) do
      :robinhood -> url(~p"/robinhood/auctions/#{auction.auction_address}/share.png")
      :base -> url(~p"/auctions/#{auction.id}/share.png")
    end
  end

  attr :share, :map, default: nil, doc: "an auction's page details, or nil for the site's own"
  attr :page_title, :string, default: nil

  @doc "The Open Graph and X card tags for the page."
  def tags(%{share: nil} = assigns) do
    ~H"""
    <meta property="og:title" content={@page_title || "Autolaunch"} />
    <meta
      property="og:description"
      content="Autolaunch is for backing long-term agents. Raise early funds through a CCA auction. No early snipers here. If you are in the auction, you are early."
    />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="Autolaunch" />
    <meta property="og:image" content={url(~p"/images/og-image.png")} />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta
      property="og:image:alt"
      content="agents: autolaunch your token. CCA auctions for agents, with Revstake and Memestake."
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

  @doc "The auction's picture as PNG bytes, with its figures as read at `now`."
  @spec png(struct(), DateTime.t()) :: {:ok, binary()} | {:error, term()}
  def png(auction, now) do
    chain = chain(auction)
    figures = figures(auction, rate(auction, chain), now)

    with {:ok, avatar} <- avatar(auction),
         {:ok, {canvas, _flags}} <- Operation.svgload_buffer(svg(auction, chain, avatar, figures)),
         {:ok, card} <- write_text(canvas, text(auction, figures, now)) do
      Image.write_to_buffer(card, ".png")
    end
  end

  @doc false
  # The figures in words, each nil while the site does not know it.
  def figures(auction, rate, now) do
    raised = auction.currency_raised
    minimum = minimum(auction)
    symbol = auction.quote_token_symbol

    %{
      fdv: money(auction.fdv, rate, symbol),
      volume: money(auction.bid_volume, rate, symbol),
      met: raised && percent(raised, minimum),
      minimum: "of #{money(minimum, rate, symbol)} minimum",
      status: status(auction, now)
    }
  end

  defp chain(auction),
    do: if(RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base)

  # No dollar value is shown for a test network's coins.
  defp rate(auction, :robinhood) do
    if RobinhoodLab.test_chain?(),
      do: nil,
      else: UsdValue.stock_rate(MarketData.prices(:robinhood), auction.quote_token_symbol)
  end

  defp rate(auction, :base), do: if(Lab.test_chain?(), do: nil, else: UsdValue.rate(auction))

  defp minimum(auction),
    do:
      auction.required_currency_raised
      |> String.to_integer()
      |> Rpc.format_units(auction.quote_token_decimals)
      |> Decimal.new()

  defp percent(raised, minimum),
    do: raised |> Decimal.mult(100) |> Decimal.div_int(minimum) |> Decimal.to_integer()

  defp status(%{state: :active, estimated_end_at: %DateTime{} = ends}, now) do
    case DateTime.diff(ends, now) do
      left when left > 0 -> "Live · #{duration(left)} left"
      _over -> "Live"
    end
  end

  defp status(auction, _now), do: MarketCard.state_label(auction.state)

  defp duration(seconds) when seconds >= 86_400,
    do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"

  defp duration(seconds) when seconds >= 3_600,
    do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  defp duration(seconds), do: "#{max(div(seconds, 60), 1)}m"

  # Dollars at the currency's market price, or the currency itself where no
  # price is known.
  defp money(nil, _rate, _symbol), do: nil
  defp money(amount, %Decimal{} = rate, _symbol), do: "$" <> short(Decimal.mult(amount, rate))
  defp money(amount, _rate, symbol), do: short(amount) <> " " <> symbol

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

  defp avatar(auction) do
    case StoredImage.bytes(auction.image) do
      {:ok, bytes} ->
        with {:ok, image} <-
               Operation.thumbnail_buffer(bytes, @avatar,
                 height: @avatar,
                 crop: :VIPS_INTERESTING_CENTRE
               ),
             do: Image.write_to_buffer(image, ".png")

      :error ->
        {:ok, nil}
    end
  end

  defp svg(auction, chain, avatar, figures) do
    color = auction.image_color || "#6b6b80"

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}">
      <defs>
        <radialGradient id="glow" cx="0.12" cy="0.18" r="0.95">
          <stop offset="0" stop-color="#{color}" stop-opacity="0.5"/>
          <stop offset="1" stop-color="#0b0b10" stop-opacity="0"/>
        </radialGradient>
        <clipPath id="avatar"><rect x="#{@margin}" y="#{@margin}" width="#{@avatar}" height="#{@avatar}" rx="32"/></clipPath>
      </defs>
      <rect width="#{@width}" height="#{@height}" fill="#0b0b10"/>
      <rect width="#{@width}" height="#{@height}" fill="url(#glow)"/>
      #{avatar_svg(avatar, color)}
      <image x="#{@left}" y="200" width="#{@chains[chain].logo_width}" height="#{@logo_height}"
        href="data:image/svg+xml;base64,#{Base.encode64(logo(chain))}"/>
      #{progress_svg(figures, @chains[chain].color)}
    </svg>
    """
  end

  defp avatar_svg(nil, color),
    do:
      ~s|<rect x="#{@margin}" y="#{@margin}" width="#{@avatar}" height="#{@avatar}" rx="32" fill="#{color}"/>|

  defp avatar_svg(png, _color),
    do:
      ~s|<image x="#{@margin}" y="#{@margin}" width="#{@avatar}" height="#{@avatar}" clip-path="url(#avatar)" href="data:image/png;base64,#{Base.encode64(png)}"/>|

  # The bar under the minimum raise, full at the minimum.
  defp progress_svg(figures, color) do
    case Enum.find_index(columns(figures), &match?({:minimum, _}, &1)) do
      nil -> ""
      index -> progress_bar(figures.met, @margin + index * @column, color)
    end
  end

  defp progress_bar(met, x, color) do
    bar = @column - 16
    filled = max(round(bar * min(met, 100) / 100), 10)

    """
    <rect x="#{x}" y="452" width="#{bar}" height="10" rx="5" fill="#ffffff" fill-opacity="0.14"/>
    <rect x="#{x}" y="452" width="#{filled}" height="10" rx="5" fill="#{color}"/>
    """
  end

  # A logo shipped with the site; the chain is :base or :robinhood, never a request's input.
  # sobelow_skip ["Traversal.FileModule"]
  defp logo(chain), do: File.read!(share_file("#{chain}.svg"))

  # Each line of words: its size, weight, colour, and the corner it hangs
  # from, its top left or, for `:right`, its top right.
  defp text(auction, figures, now) do
    [
      {truncate(auction.title, 22), 60, :bold, "#ffffff", {@left, 70}},
      {auction.token_symbol, 36, :regular, "#b8b8c8", {@left, 146}},
      {figures.status, 30, :bold, status_color(auction.state), {@left, 256}},
      {"autolaunch.sh", 30, :bold, "#ffffff", {@margin, 552}},
      {"As of #{Calendar.strftime(now, "%b %-d, %H:%M")} UTC", 22, :regular, "#8a8a9c",
       {:right, @width - @margin, 558}}
    ] ++
      Enum.flat_map(Enum.with_index(columns(figures)), fn {column, index} ->
        column_lines(column, {@margin + index * @column, 350})
      end)
  end

  # The known figures, left to right, with no gap for an unknown one.
  defp columns(figures),
    do:
      Enum.reject(
        [
          {:stat, {"FDV", figures.fdv}},
          {:stat, {"Bid volume", figures.volume}},
          {:minimum, figures}
        ],
        fn
          {:stat, {_label, value}} -> is_nil(value)
          {:minimum, %{met: met}} -> is_nil(met)
        end
      )

  defp column_lines({:stat, {label, value}}, {x, y}),
    do: [
      {label, 24, :regular, "#8a8a9c", {x, y}},
      {value, 44, :bold, "#ffffff", {x, y + 36}}
    ]

  defp column_lines({:minimum, figures}, {x, y}),
    do: [
      {"Minimum raise", 24, :regular, "#8a8a9c", {x, y}},
      {"#{figures.met}% met", 44, :bold, "#ffffff", {x, y + 36}},
      {figures.minimum, 22, :regular, "#8a8a9c", {x, y + 122}}
    ]

  defp status_color(:active), do: "#3ddc84"
  defp status_color(:graduated), do: "#3ddc84"
  defp status_color(:failed), do: "#ff6b6b"
  defp status_color(_state), do: "#d8d8e4"

  defp truncate(words, max) do
    if String.length(words) > max,
      do: String.slice(words, 0, max - 1) <> "…",
      else: words
  end

  defp write_text(canvas, lines) do
    Enum.reduce_while(lines, {:ok, canvas}, fn {words, size, weight, color, at}, {:ok, card} ->
      with {:ok, {layer, _flags}} <- words_layer(words, size, weight, color),
           {x, y} = corner(at, layer),
           {:ok, card} <- Operation.composite2(card, layer, :VIPS_BLEND_MODE_OVER, x: x, y: y) do
        {:cont, {:ok, card}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp corner({:right, x, y}, layer), do: {x - Image.width(layer), y}
  defp corner({x, y}, _layer), do: {x, y}

  defp words_layer(words, size, weight, color) do
    {face, file} = font(weight)

    Operation.text(
      ~s|<span foreground="#{color}">#{escape(words)}</span>|,
      font: "#{face} #{size}",
      fontfile: file,
      rgba: true,
      dpi: 72
    )
  end

  defp font(:bold), do: {"Geist SemiBold", share_file("Geist-SemiBold.ttf")}
  defp font(:regular), do: {"Geist", share_file("Geist-Regular.ttf")}

  defp share_file(name), do: Application.app_dir(:autolaunch, ["priv", "share_card", name])

  defp escape(words), do: words |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
