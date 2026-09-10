defmodule AutolaunchWeb.Plugs.LaunchImage do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @digest ~r/\A[0-9a-f]{64}\z/

  @impl true
  def init(options), do: options

  # This endpoint returns immutable, signature-validated image bytes. The
  # persisted content type is constrained to PNG, JPEG, or WebP at ingestion.
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  @impl true
  def call(%Plug.Conn{method: "GET", path_info: [lane, id, digest]} = conn, _options)
      when lane in ["images", "stock-images"] do
    with {:ok, _uuid} <- Ecto.UUID.cast(id),
         true <- Regex.match?(@digest, digest),
         {:ok, image} when not is_nil(image) <- fetch_image(lane, id, digest) do
      conn
      |> put_resp_content_type(image.content_type)
      |> put_resp_header("content-length", Integer.to_string(image.byte_size))
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", ~s("sha256-#{digest}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, image.bytes)
      |> halt()
    else
      _not_exact -> not_found(conn)
    end
  end

  def call(conn, _options), do: conn

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
