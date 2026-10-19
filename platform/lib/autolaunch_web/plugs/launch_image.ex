defmodule AutolaunchWeb.Plugs.LaunchImage do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias Autolaunch.StoredImage

  @digest ~r/\A[0-9a-f]{64}\z/
  @lanes ["images", "stock-images"]

  @impl true
  def init(options), do: options

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: [lane, id, digest]} = conn, _options)
      when lane in @lanes do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         true <- Regex.match?(@digest, digest),
         {:ok, image} when not is_nil(image) <- fetch_image(lane, id, digest) do
      send_image(conn, image.content_type, image.bytes, ~s("sha256-#{digest}"))
    else
      _not_exact -> not_found(conn)
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: [lane, id, digest, size]} = conn, _options)
      when lane in @lanes do
    with {:ok, width} <- StoredImage.width(size),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         true <- Regex.match?(@digest, digest),
         {:ok, webp} <- StoredImage.sized_bytes({lane, uuid, digest}, width) do
      send_image(conn, "image/webp", webp, ~s("sha256-#{digest}-#{width}"))
    else
      _not_exact -> not_found(conn)
    end
  end

  def call(conn, _options), do: conn

  # Immutable, signature-validated image bytes: the stored content type is
  # constrained to PNG, JPEG or WebP at ingestion, and a sized copy is WebP.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  defp send_image(conn, content_type, bytes, etag) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("etag", etag)
    |> merge_resp_headers(AutolaunchWeb.static_headers())
    |> send_resp(200, bytes)
    |> halt()
  end

  defp fetch_image("images", id, digest),
    do: Autolaunch.get_public_launch_draft_image(id, digest, actor: nil)

  defp fetch_image("stock-images", id, digest),
    do: Autolaunch.get_public_stock_launch_draft_image(id, digest, actor: nil)

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not found")
    |> halt()
  end
end
