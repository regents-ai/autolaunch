defmodule AutolaunchWeb.Plugs.RuntimeSession do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    options = Application.fetch_env!(:autolaunch, :session_options)
    Plug.Session.call(conn, Plug.Session.init(options))
  end
end
