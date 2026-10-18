defmodule AutolaunchWeb.ShareCard.Draw do
  @moduledoc """
  What the share picture and the share video draw alike: the words in the
  card's fonts, the token's round logo, the chain's mark, the ticker line and
  the figures in dollars or in the launch's own currency.

  Names and tickers are the creator's own words, so they are drawn as plain
  text, without the symbols the fonts cannot draw, and cut short to fit.
  """

  alias Autolaunch.Lab
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.MarketData
  alias Autolaunch.StoredImage
  alias AutolaunchWeb.{TokenDisplay, UsdValue}
  alias Vix.Vips.{Image, Operation}

  @tangerine "#ff5b19"
  @chains %{
    base: %{name: "Base", width: 1280, height: 323.84},
    robinhood: %{name: "Robinhood Chain", width: 1576, height: 207}
  }

  @doc "The chain a launch is on: `:base` or `:robinhood`."
  def chain(auction),
    do: if(RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base)

  @doc "The chain's name as people know it."
  def chain_name(chain), do: @chains[chain].name

  @doc "How wide the chain's mark is drawn at `height`."
  def mark_width(chain, height), do: round(height * @chains[chain].width / @chains[chain].height)

  @doc "The chain's mark, as the SVG shipped with the site."
  # The chain is :base or :robinhood, never a request's input.
  # sobelow_skip ["Traversal.FileModule"]
  def chain_mark(chain), do: File.read!(share_file("#{chain}.svg"))

  @doc """
  The ticker line: `$TOKEN / STOCK` for a launch paired with a stock token,
  `$TOKEN` for one paired with none.
  """
  def ticker(%{kind: :stocks} = auction),
    do: "$" <> plain(auction.token_symbol) <> " / " <> plain(auction.quote_token_symbol)

  def ticker(auction), do: "$" <> plain(auction.token_symbol)

  @doc "Dollars per whole unit of the launch's currency, or nil where none is known."
  # No dollar value is shown for a test network's coins.
  def rate(auction) do
    case chain(auction) do
      :robinhood ->
        if RobinhoodLab.test_chain?(),
          do: nil,
          else: UsdValue.stock_rate(MarketData.prices(:robinhood), auction.quote_token_symbol)

      :base ->
        if Lab.test_chain?(), do: nil, else: UsdValue.rate(auction)
    end
  end

  @doc """
  An amount of the launch's currency in dollars at its market price, or in
  the currency itself where no price is known.
  """
  def money(nil, _rate, _auction), do: nil
  def money(amount, %Decimal{} = rate, _auction), do: "$" <> short(Decimal.mult(amount, rate))
  def money(amount, _rate, auction), do: short(amount) <> " " <> auction.quote_token_symbol

  @scales [{1_000_000_000, "B"}, {1_000_000, "M"}, {1_000, "K"}]

  @doc "An amount to three significant digits, with K, M or B for the large ones."
  def short(amount) do
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

  @doc "A stored colour in its one shape, `#rrggbb`, or the card's tangerine."
  def color(color) when is_binary(color) do
    if Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, color), do: color, else: @tangerine
  end

  def color(_color), do: @tangerine

  @doc "The launch's image as a square PNG `size` wide, or nil when it has none."
  def logo(auction, size) do
    case StoredImage.bytes(auction.image) do
      {:ok, bytes} ->
        with {:ok, image} <-
               Operation.thumbnail_buffer(bytes, size,
                 height: size,
                 crop: :VIPS_INTERESTING_CENTRE
               ),
             do: Image.write_to_buffer(image, ".png")

      :error ->
        {:ok, nil}
    end
  end

  @doc """
  A creator's words without control characters or the pictographs the fonts
  cannot draw, on one line.
  """
  def plain(words) do
    words
    |> String.replace(
      ~r/[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{So}\x{FE00}-\x{FE0F}\x{1F3FB}-\x{1F3FF}]/u,
      ""
    )
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  The words on one line no wider than `max`, cut short with an ellipsis where
  they run over.
  """
  def fit(words, weight, size, color, max) do
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

  @doc "The words drawn in one of the card's fonts (`:bold`, `:regular`, `:pixel`) and a colour."
  def layer(words, weight, size, color) do
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
