defmodule Autolaunch.StoredImage do
  @moduledoc """
  The launch images the site stores, named by the address it gave each one:
  `/images/<id>/<digest>` for a Revstake draft's image and
  `/stock-images/<id>/<digest>` for a Memestock draft's, on any host.

  Pages show each image at the size they draw it, from
  `<address>/<width>.webp`: a square of that width cut from the image's
  centre, as the pages' square frames show it, never enlarged, made the
  first time it is asked for (one at a time, by `Autolaunch.StoredImage.Resizer`)
  and kept in memory. The large pictures offer two widths and the
  browser takes the one the screen needs. The address without a width stays
  the image's own bytes, for share pictures and videos.
  """

  alias Autolaunch.StoredImage.Resizer

  @digest ~r/\A[0-9a-f]{64}\z/
  # Twice the largest size a page draws each kind of picture at: 96 for the
  # ticker, swap and list icons (up to 48 pixels), 160 for the bid window's
  # and finished auction's pictures (up to 72), 640 for the cards and a
  # token's own page (up to about 320), and 320 for those on a phone, where
  # they are drawn at about 150 to 200.
  @widths [96, 160, 320, 640]
  @choices [320, 640]
  @cache :autolaunch_stored_image_sizes
  @kept 300

  @type key :: {String.t(), String.t(), String.t()}
  @type width :: 96 | 160 | 320 | 640

  @doc "The sized copies' cache and how many it keeps, for the application's supervisor."
  def cache, do: @cache
  def kept, do: @kept

  @doc "The width a sized copy's file name asks for, as 320 for `320.webp`, or `:error`."
  @spec width(String.t()) :: {:ok, width()} | :error
  def width(name), do: Enum.find_value(@widths, :error, &(name == "#{&1}.webp" && {:ok, &1}))

  @doc "The lane, id and digest an address names, or `:error` for any other address."
  @spec key(String.t()) :: {:ok, key()} | :error
  def key(url) when is_binary(url) do
    with %URI{path: path} when is_binary(path) <- URI.parse(url),
         [lane, id, digest] when lane in ["images", "stock-images"] <-
           String.split(path, "/", trim: true),
         {:ok, id} <- Ecto.UUID.cast(id),
         true <- Regex.match?(@digest, digest) do
      {:ok, {lane, id, digest}}
    else
      _other -> :error
    end
  end

  @doc """
  Where a page shows the image at `width`: a stored image's sized copy, and
  any other address, such as one on IPFS or another site, as it is.
  """
  @spec sized(String.t(), width()) :: String.t()
  def sized(url, width) when is_binary(url) and width in @widths do
    case key(url) do
      {:ok, _key} ->
        uri = URI.parse(url)
        URI.to_string(%URI{uri | path: uri.path <> "/#{width}.webp"})

      :error ->
        url
    end
  end

  @doc """
  The widths a large picture's browser chooses from, as an `<img>`'s
  `srcset`, beside `sized(url, 640)` as its `src`; nil for an address that
  is not a stored image, which is shown as it is.
  """
  @spec choices(String.t()) :: String.t() | nil
  def choices(url) when is_binary(url) do
    case key(url) do
      {:ok, _key} -> Enum.map_join(@choices, ", ", &"#{sized(url, &1)} #{&1}w")
      :error -> nil
    end
  end

  @doc "The bytes of the stored image an address names, or `:error`."
  @spec bytes(String.t() | nil) :: {:ok, binary()} | :error
  def bytes(url) when is_binary(url) do
    with {:ok, {lane, id, digest}} <- key(url),
         {:ok, %{bytes: bytes}} <- fetch(lane, id, digest) do
      {:ok, bytes}
    else
      _other -> :error
    end
  end

  def bytes(_url), do: :error

  @doc "The WebP square `width` pixels wide of the stored image `key` names, or `:error`."
  @spec sized_bytes(key(), width()) :: {:ok, binary()} | :error
  def sized_bytes({_lane, _id, _digest} = key, width) when width in @widths do
    case Cachex.fetch(@cache, {key, width}, fn -> resize(key, width) end) do
      {found, webp} when found in [:ok, :commit] and is_binary(webp) -> {:ok, webp}
      _missing -> :error
    end
  end

  # The record is read here, so an address with nothing stored answers at
  # once; only the copy itself waits for the one resizer.
  defp resize({lane, id, digest}, width) do
    with {:ok, %{bytes: bytes}} <- fetch(lane, id, digest),
         {:ok, webp} <- Resizer.webp(bytes, width) do
      {:commit, webp}
    else
      _missing -> {:ignore, :error}
    end
  end

  defp fetch("images", id, digest),
    do: Autolaunch.get_public_launch_draft_image(id, digest, actor: nil)

  defp fetch("stock-images", id, digest),
    do: Autolaunch.get_public_stock_launch_draft_image(id, digest, actor: nil)
end
