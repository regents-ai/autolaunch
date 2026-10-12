defmodule AutolaunchWeb.Plugs.Panels do
  @moduledoc """
  Reads whether the visitor last left the side panel open, so the first server
  render already draws it that way: closed until they choose otherwise. The
  browser writes the cookie (`assets/js/shell_panels.ts`); only the two values
  the panel can take are ever accepted, since they reach an HTML attribute.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    assign(
      conn,
      :aside,
      if(conn.req_cookies["autolaunch_aside"] == "open", do: "open", else: "closed")
    )
  end
end
