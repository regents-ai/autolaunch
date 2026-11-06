defmodule AutolaunchWeb.AccountLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  @moduletag :capture_log

  # ACCOUNT_SHOWS_A_PAIRED_AGENT: the shared agents list needs every field of a
  # row the Agents page builds; a missing `kind` crashed the page for everyone
  # with a paired agent (v140), and no case had a paired agent. The row's `wallet`
  # is what puts the agent's address beside its name.
  test "ACCOUNT_SHOWS_A_PAIRED_AGENT", %{conn: conn} do
    account = TestSupport.register_creator!()

    code =
      RegentAgents.issue_pairing_code!(
        actor: %RegentAgents.Person{privy_user_id: account.privy_user_id}
      )

    agent =
      RegentAgents.pair_agent!(code.code, "Account Page Agent", :codex,
        actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate("ab", 20)}
      )

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account/agents")

    render_async(view, 1_000)
    agents = view |> element("#account-agents") |> render()
    assert agents =~ "Account Page Agent"
    assert agents =~ "Codex"
    assert has_element?(view, "#account-agents-agent-#{agent.id}-wallet")
  end

  # PAIRING_CODE_KEPT_PER_AGENT: the pairing box held one code and made a new one
  # on every agent choice, so choosing Codex, then Hermes, then Codex again showed
  # a third code and the message already pasted to Codex no longer matched the
  # screen (27 Oct 2026). Each agent now keeps its code until it expires, and
  # "Make a new code" replaces only the chosen agent's, as ash-template's box does.
  test "PAIRING_CODE_KEPT_PER_AGENT", %{conn: conn} do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/account/agents")

    render_async(view, 1_000)
    box = form(view, "#shell-pairing-box")
    shown = fn -> pairing_code(view) end

    render_change(box, %{harness: "codex"})
    codex = shown.()
    render_change(box, %{harness: "hermes"})
    hermes = shown.()
    render_change(box, %{harness: "codex"})

    assert codex != hermes
    assert shown.() == codex

    render_submit(box, %{harness: "codex"})
    renewed = shown.()
    assert renewed != codex

    render_change(box, %{harness: "hermes"})
    assert shown.() == hermes
    render_change(box, %{harness: "codex"})
    assert shown.() == renewed
  end

  # ACCOUNT_MENU_ON_EVERY_PAGE: the account's button opens one menu on every page,
  # a LiveView page and one served without LiveView alike, listing at most three of
  # the person's agents, newest paired first, and its Pair New Agent opens the one
  # pairing window over that page, which holds the pairing box. A page without the
  # menu or the window leaves people no way to pair.
  test "ACCOUNT_MENU_ON_EVERY_PAGE", %{conn: conn} do
    account = TestSupport.register_creator!()
    person = %RegentAgents.Person{privy_user_id: account.privy_user_id}

    for {name, digit} <- [
          {"Menu One", "1"},
          {"Menu Two", "2"},
          {"Menu Three", "3"},
          {"Menu Four", "4"}
        ] do
      code = RegentAgents.issue_pairing_code!(actor: person)

      RegentAgents.pair_agent!(code.code, name, :codex,
        actor: %RegentAgents.Agent{wallet: "0x" <> String.duplicate(digit, 40)}
      )
    end

    session = signed_in_session(account.id)
    signed_in = conn |> Phoenix.ConnTest.init_test_session(session)

    # A page served without LiveView lists the newest three, without activity lines,
    # and holds the pairing window's box in a LiveView of its own.
    html = signed_in |> get("/about") |> html_response(200)
    assert html =~ ~s(id="account-menu")
    assert html =~ ~s(aria-controls="shell-pairing")
    assert html =~ ~s(<form id="shell-pairing-box")
    refute html =~ "Menu One"
    for name <- ["Menu Two", "Menu Three", "Menu Four"], do: assert(html =~ name)

    # The page drew the window's nested view for this browser's session.
    {:ok, window, _html} =
      signed_in
      |> connects_with(session)
      |> live_isolated(AutolaunchWeb.PairWindowLive,
        session: %{"render_topic" => session["live_socket_id"]}
      )

    window |> form("#shell-pairing-box") |> render_change(%{harness: "codex"})
    assert render(window) =~ "Pairing code:"

    # A LiveView page reads them in the menu's own component, the same three.
    {:ok, view, _html} = signed_in |> connects_with(session) |> live("/auctions")
    menu = view |> element("#account-menu") |> render()
    assert menu =~ ~s(aria-controls="shell-pairing")
    assert menu =~ "Manage Account"
    assert menu =~ "Sign out"
    refute menu =~ "Menu One"
    for name <- ["Menu Two", "Menu Three", "Menu Four"], do: assert(menu =~ name)

    assert has_element?(view, "#shell-pairing #shell-pairing-box")

    # The Agents page's Pair New Agent opens the same window; the page holds no
    # second box.
    {:ok, page, _html} = signed_in |> connects_with(session) |> live("/account/agents")
    render_async(page, 1_000)
    assert has_element?(page, ~s(#account-agents button[aria-controls="shell-pairing"]))
    assert length(Regex.scan(~r/class="rg-account__pair"/, render(page))) == 1

    # The Account page puts this site's own sections before the account card.
    {:ok, page, _html} = signed_in |> connects_with(session) |> live("/account")
    render_async(page, 1_000)
    html = render(page)
    {connections, _} = :binary.match(html, ~s(id="account-connections"))
    {identity, _} = :binary.match(html, ~s(id="account-identity"))
    assert connections < identity
  end

  # The code in the message the box shows for the chosen agent.
  defp pairing_code(view) do
    message = view |> element("#shell-pairing-box pre") |> render()
    [_, code] = Regex.run(~r/Pairing code:\s*([^\s<]+)/, message)
    code
  end
end
