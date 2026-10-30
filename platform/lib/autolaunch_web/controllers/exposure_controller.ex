defmodule AutolaunchWeb.ExposureController do
  @moduledoc """
  Exposure over HTTP for anyone, and for the person signed in on this site:
  every series and one series need no account; the signed-in person's own
  holding is read for the wallet they signed in with. Each calls the same
  `Autolaunch.Exposure` operation the page and the agent routes call
  (`AutolaunchWeb.ExposureAnswer`).

  It also serves a series' terms, the exact bytes whose keccak256 the series
  holds as `termsHash`, and the Exposure styles, built outside `priv/static`
  (`esbuild exposure`), so they are there only while Exposure is on.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Actors.Human
  alias Autolaunch.Exposure
  alias AutolaunchWeb.ExposureAnswer, as: Answer

  # Asked for on every page while on; the browser keeps its copy until the file changes.
  # The path is the release's own built file; nothing in the request names it.
  # sobelow_skip ["Traversal.FileModule"]
  def stylesheet(conn, _params) do
    css = File.read!(Application.app_dir(:autolaunch, "priv/exposure/exposure.css"))
    etag = ~s("#{Base.encode16(:crypto.hash(:sha256, css), case: :lower)}")
    conn = conn |> put_resp_header("etag", etag) |> put_resp_header("cache-control", "no-cache")

    if etag in get_req_header(conn, "if-none-match"),
      do: send_resp(conn, 304, ""),
      else: conn |> put_resp_content_type("text/css") |> send_resp(200, css)
  end

  # The file is named by the hash itself, checked to be 32 bytes of hex first.
  # sobelow_skip ["Traversal.FileModule"]
  def terms(conn, %{"hash" => "0x" <> hex}) when byte_size(hex) == 64 do
    with {:ok, _bytes} <- Base.decode16(hex, case: :lower),
         {:ok, text} <-
           File.read(Application.app_dir(:autolaunch, "priv/exposure_terms/0x#{hex}.md")) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, text)
    else
      _unknown -> Answer.refuse(conn, :unknown_terms)
    end
  end

  def terms(conn, _params), do: Answer.refuse(conn, :unknown_terms)

  def index(conn, params) do
    if params == %{},
      do: Answer.send(conn, Exposure.exposure_series_list(actor: nil), :list),
      else: Answer.refuse(conn, :invalid_request)
  end

  def show(conn, %{"series" => series} = params) do
    if map_size(params) == 1,
      do: Answer.send(conn, Exposure.exposure_series(series, actor: nil), :series),
      else: Answer.refuse(conn, :invalid_request)
  end

  def mine(%{assigns: %{current_human_account: nil}} = conn, _params),
    do: Answer.refuse(conn, :authentication_required)

  def mine(%{assigns: %{current_human_account: account}} = conn, %{"series" => series}) do
    actor = %Human{human_account_id: account.id}
    Answer.send(conn, Exposure.exposure_holdings(series, actor: actor), :holdings)
  end
end
