defmodule AutolaunchWeb.Components.ShellRenderTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.AccessContext
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias AutolaunchWeb.Components.AccountControl
  alias AutolaunchWeb.Components.Rail
  alias AutolaunchWeb.Components.TopBar

  @wallet "0x1111111111111111111111111111111111111111"

  test "the rail lists every site link and marks the active path" do
    html = render_component(&Rail.rail/1, current_path: "/auctions/demo")

    assert html =~ ~s(aria-label="Site")
    assert html =~ ~s(href="/")
    assert html =~ "Home"
    assert html =~ ~s(href="/create")
    assert html =~ "Create"
    assert html =~ ~s(href="/auctions")
    assert html =~ "Auctions"
    assert html =~ ~s(href="/tokens")
    assert html =~ "Tokens"
    assert html =~ ~s(href="/portfolio")
    assert html =~ "Portfolio"
    assert html =~ ~s(href="/regent")
    assert html =~ "REGENT"
    assert html =~ ~s(aria-current="page")
    refute html =~ ~s(aria-label="Home" aria-current="page")
    refute html =~ ~s(aria-current="page" aria-label="Home")
  end

  test "Home is current only on the public root" do
    assert Rail.active?("/", "/")
    refute Rail.active?("/create", "/")
    assert Rail.active?("/create", "/create")
    assert Rail.active?("/tokens/1", "/tokens")
    refute Rail.active?("/tokens", "/portfolio")
  end

  test "the top bar search form posts a query to home" do
    html =
      render_component(&TopBar.top_bar/1,
        account_control: AccessContext.account_control(AccessContext.anonymous())
      )

    assert html =~ ~s(action="/")
    assert html =~ ~s(method="get")
    assert html =~ ~s(name="q")
    assert html =~ "Search for coins and users..."
  end

  test "signed-out account control carries the auth_lazy sign-in contract" do
    html =
      render_component(&AccountControl.account_control/1,
        account_control: AccessContext.account_control(AccessContext.anonymous())
      )

    assert html =~ ~s(id="account-control")
    assert html =~ ~s(data-account-kind="sign_in")
    assert html =~ ~s(data-account-target="sign-in")
    assert html =~ "Sign in"
    assert html =~ ~s(id="account-auth-status")
    refute html =~ ~s(data-account-target="sign-out")
  end

  test "signed-in account control shows the label, Portfolio, and Sign out" do
    account = account!()

    html =
      render_component(&AccountControl.account_control/1,
        account_control: AccessContext.account_control(AccessContext.human(account))
      )

    assert html =~ ~s(data-account-kind="signed_in")
    assert html =~ "0x1111…1111"
    assert html =~ ~s(href="/portfolio")
    assert html =~ "Portfolio"
    assert html =~ ~s(data-account-target="sign-out")
    assert html =~ "Sign out"
    assert html =~ ~s(id="account-auth-status")
    refute html =~ "Sign in"
  end

  test "product pages render one shell control and the active rail item", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tokens")

    assert has_element?(view, ~s(nav[aria-label="Site"] a[href="/tokens"][aria-current="page"]))
    assert has_element?(view, "#account-control[data-account-kind=sign_in]")
    assert has_element?(view, "#account-control [data-account-target=sign-in]", "Sign in")
    assert has_element?(view, "#account-auth-status")
    assert has_element?(view, ~s(form.shell-search[action="/"] input[name="q"]))
  end

  test "a signed-in portfolio visit keeps data-account-kind on the shell control", %{
    conn: conn
  } do
    account = account!()

    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/portfolio")

    assert has_element?(view, "#account-control[data-account-kind=signed_in]")
    assert has_element?(view, "#account-control [data-account-target=sign-out]", "Sign out")
    refute has_element?(view, "#autolaunch-holdings #account-control")
  end

  defp account! do
    Accounts.register_verified!(
      "did:privy:shell:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end
end
