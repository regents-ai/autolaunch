defmodule AutolaunchWeb.Plugs.Parsers do
  @moduledoc """
  `Plug.Parsers`, with a body it refuses reported against the request as it
  stands here. Phoenix otherwise renders that error for the request as it
  entered the endpoint, before `RegentAgentAccess.Plug` chose JSON for `/api`
  addresses, so an API caller sending an unreadable body got an HTML page.

  A body over its limit, or one that does not decode, is reported against the
  request its last read returned (`AutolaunchWeb.Plugs.Parsers.LastRead`).
  """
  @behaviour Plug

  @impl Plug
  def init(opts) do
    {parsers, opts} = Keyword.pop!(opts, :parsers)

    Plug.Parsers.init(
      [parsers: Enum.map(parsers, &{AutolaunchWeb.Plugs.Parsers.LastRead, parser: &1})] ++ opts
    )
  end

  @impl Plug
  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    error -> Plug.Conn.WrapperError.reraise(conn, :error, error, __STACKTRACE__)
  end
end
