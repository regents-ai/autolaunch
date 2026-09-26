defmodule AutolaunchWeb.Plugs.PageShell do
  @moduledoc "Puts a controller page inside the product shell: rail, top bar and account control."
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    access =
      case conn.assigns[:current_human_account] do
        nil -> Autolaunch.AccessContext.anonymous()
        account -> Autolaunch.AccessContext.human(account)
      end

    conn
    |> Phoenix.Controller.put_layout(html: {AutolaunchWeb.Layouts, :app})
    |> assign(:current_path, conn.request_path)
    |> assign(:search_query, "")
    |> assign(:account_control, Autolaunch.AccessContext.account_control(access))
  end
end
