defmodule Autolaunch.ImageColor do
  @moduledoc """
  The one colour a launch image is known by: its strongest hue, found once
  when the image is stored and kept beside its bytes, so every card can tint
  itself without reading the image again.

  The image is shrunk to a small square and its opaque pixels grouped by hue,
  each weighted by how colourful it is, so a small bright area beats a large
  dull one. The heaviest group's average colour wins. When that colour and its
  two neighbouring hues are both small and dull, the image is known by a
  neutral grey: a photo whose strongest colour is a dull patch of skin is grey,
  while a small vivid logo on black keeps its colour. Either way the lightness is kept in a band that reads against
  both the light and the dark theme.

  Images are stored at `/images/<id>/<digest>` and `/stock-images/<id>/<digest>`;
  `for_urls/1` reads the colours of such addresses in one query per table.
  """

  alias Vix.Vips.{Image, Operation}

  @side 64
  @buckets 24
  @min_alpha 128
  # A pixel this close to grey carries no hue.
  @min_chroma 38
  # The winning hue and its neighbours keep their colour when they cover this
  # share of the image, weighted by chroma, or are this vivid on average.
  @min_share 0.06
  @vivid_chroma 80
  @min_lightness 0.42
  @max_lightness 0.62
  @grey_lightness 0.52

  @doc "The image's colour as `#rrggbb`, or why its bytes could not be read."
  @spec dominant(binary()) :: {:ok, String.t()} | {:error, :invalid_image}
  def dominant(bytes) when is_binary(bytes) do
    with {:ok, pixels} <- pixels(bytes), do: {:ok, pixels |> pick() |> hex()}
  end

  @doc """
  The colours of stored images, keyed by the address each was asked for.
  An address that names no stored image of the site is left out.
  """
  @spec for_urls([String.t() | nil]) :: %{String.t() => String.t()}
  def for_urls(urls) do
    named = for url <- Enum.uniq(urls), is_binary(url), {:ok, key} <- [key(url)], do: {url, key}

    colours =
      named
      |> Enum.group_by(fn {_url, {lane, _id, _digest}} -> lane end, fn {_url, {_, id, _}} ->
        id
      end)
      |> Enum.flat_map(fn {lane, ids} -> stored(lane, ids) end)
      |> Map.new(fn image -> {{image.id, image.digest}, image.color} end)

    for {url, {_lane, id, digest}} <- named,
        colour = colours[{id, digest}],
        into: %{},
        do: {url, colour}
  end

  @doc "The colour of one stored image's address, or nil."
  @spec for_url(String.t() | nil) :: String.t() | nil
  def for_url(url), do: for_urls([url])[url]

  defp key(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(url),
         [lane, id, digest] when lane in ["images", "stock-images"] <-
           String.split(path, "/", trim: true),
         {:ok, id} <- Ecto.UUID.cast(id),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      {:ok, {lane, id, digest}}
    else
      _other -> :error
    end
  end

  defp stored("images", ids), do: Autolaunch.launch_draft_image_colors!(ids, actor: nil)

  defp stored("stock-images", ids),
    do: Autolaunch.stock_launch_draft_image_colors!(ids, actor: nil)

  # Every opaque pixel of the shrunk image as `{r, g, b}`, 8 bits each.
  defp pixels(bytes) do
    with {:ok, image} <- Operation.thumbnail_buffer(bytes, @side, height: @side),
         {:ok, image} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
         {:ok, image} <- Operation.cast(image, :VIPS_FORMAT_UCHAR),
         {:ok, image} <- with_alpha(image),
         {:ok, binary} <- Image.write_to_binary(image) do
      {:ok, for(<<r, g, b, a <- binary>>, a >= @min_alpha, do: {r, g, b})}
    else
      _unreadable -> {:error, :invalid_image}
    end
  rescue
    _error -> {:error, :invalid_image}
  end

  defp with_alpha(image) do
    case Image.bands(image) do
      4 -> {:ok, image}
      3 -> Operation.bandjoin_const(image, [255.0])
      _other -> {:error, :invalid_image}
    end
  end

  defp pick([]), do: grey()

  defp pick(pixels) do
    buckets =
      Enum.reduce(pixels, %{}, fn {r, g, b} = pixel, buckets ->
        chroma = Enum.max([r, g, b]) - Enum.min([r, g, b])

        if chroma >= @min_chroma,
          do: Map.update(buckets, bucket(pixel), weighed(pixel, chroma), &add(&1, pixel, chroma)),
          else: buckets
      end)

    case Enum.max_by(buckets, fn {_bucket, {_n, weight, _r, _g, _b}} -> weight end, fn -> nil end) do
      {bucket, {_n, weight, r, g, b}} ->
        {count, near} = window(buckets, bucket)

        if near < @min_share * 255 * length(pixels) and near < @vivid_chroma * count,
          do: grey(),
          else: banded({r / weight, g / weight, b / weight})

      nil ->
        grey()
    end
  end

  # How many pixels a hue and its two neighbours hold, and their summed chroma.
  defp window(buckets, bucket) do
    [bucket - 1, bucket, bucket + 1]
    |> Enum.map(&Map.get(buckets, Integer.mod(&1, @buckets), {0, 0, 0, 0, 0}))
    |> Enum.reduce({0, 0}, fn {n, w, _r, _g, _b}, {count, weight} -> {count + n, weight + w} end)
  end

  defp weighed({r, g, b}, w), do: {1, w, r * w, g * w, b * w}

  defp add({n, w0, r0, g0, b0}, {r, g, b}, w),
    do: {n + 1, w0 + w, r0 + r * w, g0 + g * w, b0 + b * w}

  defp bucket({r, g, b}) do
    {h, _s, _l} = hsl({r / 255, g / 255, b / 255})
    rem(trunc(h * @buckets), @buckets)
  end

  # A colourless image is known by a neutral grey at the middle lightness.
  defp grey, do: rgb({0.0, 0.0, @grey_lightness})

  defp banded({r, g, b}) do
    {h, s, l} = hsl({r / 255, g / 255, b / 255})
    rgb({h, s, l |> max(@min_lightness) |> min(@max_lightness)})
  end

  defp hsl({r, g, b}) do
    max = Enum.max([r, g, b])
    min = Enum.min([r, g, b])
    l = (max + min) / 2
    d = max - min

    if d == 0 do
      {0.0, 0.0, l}
    else
      s = if l > 0.5, do: d / (2 - max - min), else: d / (max + min)
      {hue({r, g, b}, max, d) / 6, s, l}
    end
  end

  defp hue({r, g, b}, max, d) when max == r, do: (g - b) / d + if(g < b, do: 6, else: 0)
  defp hue({r, g, b}, max, d) when max == g, do: (b - r) / d + 2
  defp hue({r, g, _b}, _max, d), do: (r - g) / d + 4

  defp rgb({_h, s, l}) when s == 0, do: {l, l, l}

  defp rgb({h, s, l}) do
    q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
    p = 2 * l - q
    {channel(p, q, h + 1 / 3), channel(p, q, h), channel(p, q, h - 1 / 3)}
  end

  defp channel(p, q, t) do
    t = if t < 0, do: t + 1, else: if(t > 1, do: t - 1, else: t)

    cond do
      t < 1 / 6 -> p + (q - p) * 6 * t
      t < 1 / 2 -> q
      t < 2 / 3 -> p + (q - p) * (2 / 3 - t) * 6
      true -> p
    end
  end

  defp hex({r, g, b}), do: "#" <> Base.encode16(<<byte(r), byte(g), byte(b)>>, case: :lower)

  defp byte(unit), do: unit |> Kernel.*(255) |> round() |> max(0) |> min(255)
end
