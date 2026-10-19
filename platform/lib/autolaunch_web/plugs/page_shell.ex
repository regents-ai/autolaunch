defmodule AutolaunchWeb.Plugs.PageShell do
  @moduledoc "Puts a controller page inside the product shell: rail, top bar and account control."
  @behaviour Plug

  import Plug.Conn

  alias Autolaunch.AccessContext

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> Phoenix.Controller.put_layout(html: {AutolaunchWeb.Layouts, :app})
    |> assign(:current_path, conn.request_path)
    |> assign(:account_control, account_control(conn.assigns[:current_human_account]))
  end

  # A sign-in that could not be read just then shows neither Sign in nor a name;
  # the page says something didn't load.
  defp account_control(:unreadable), do: AccessContext.unreadable_account_control()
  defp account_control(nil), do: AccessContext.account_control(AccessContext.anonymous())
  defp account_control(account), do: AccessContext.account_control(AccessContext.human(account))
end
