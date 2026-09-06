defmodule AutolaunchWeb.SharedProfileController do
  use AutolaunchWeb, :controller

  def show(conn, _params) do
    access =
      case conn.assigns.current_human_account do
        nil -> Autolaunch.AccessContext.anonymous()
        account -> Autolaunch.AccessContext.human(account)
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_layout(html: {AutolaunchWeb.Layouts, :app})
    |> render(:show,
      page_title: "Profile",
      current_path: "/profile",
      account_control: Autolaunch.AccessContext.account_control(access)
    )
  end
end
