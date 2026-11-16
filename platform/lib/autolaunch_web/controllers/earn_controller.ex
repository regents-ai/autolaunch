defmodule AutolaunchWeb.EarnController do
  @moduledoc """
  Earn over HTTP for anyone, and for the person signed in on this site: the
  products and their terms need no account; the signed-in person's own
  balances are read for the wallet they signed in with. Each calls the same
  `Autolaunch.Earn` operation the page and the agent routes call
  (`AutolaunchWeb.EarnAnswer`).

  It also serves Earn's styles, built outside `priv/static` (`esbuild earn`),
  so they are there only while Earn is on.
  """

  use AutolaunchWeb, :controller

  alias Autolaunch.Actors.Human
  alias Autolaunch.Earn
  alias AutolaunchWeb.EarnAnswer, as: Answer

  # Asked for on every page while on; the browser keeps its copy until the file changes.
  # The path is the release's own built file; nothing in the request names it.
  # sobelow_skip ["Traversal.FileModule"]
  def stylesheet(conn, _params) do
    css = File.read!(Application.app_dir(:autolaunch, "priv/earn/earn.css"))
    etag = ~s("#{Base.encode16(:crypto.hash(:sha256, css), case: :lower)}")
    conn = conn |> put_resp_header("etag", etag) |> put_resp_header("cache-control", "no-cache")

    if etag in get_req_header(conn, "if-none-match"),
      do: send_resp(conn, 304, ""),
      else: conn |> put_resp_content_type("text/css") |> send_resp(200, css)
  end

  def products(conn, params) do
    if params == %{},
      do: Answer.send(conn, Earn.earn_products(actor: nil)),
      else: Answer.refuse(conn, :invalid_request)
  end

  def mine(%{assigns: %{current_human_account: nil}} = conn, _params),
    do: Answer.refuse(conn, :authentication_required)

  def mine(%{assigns: %{current_human_account: account}} = conn, _params),
    do: Answer.send(conn, Earn.earn_positions(actor: %Human{human_account_id: account.id}))
end
