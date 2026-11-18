defmodule AutolaunchWeb.CreateReviewTest do
  @moduledoc """
  The launch review on the create pages takes the form's place: Review launch
  opens it with the wallet button at its foot, the same button beside it then
  reads Continue Editing and brings the form back as it was. What a draft
  still needs follows the form as it is typed, not the last save, and each
  field saves when the person leaves it. A Revstake creator with no X, GitHub
  or ENS account on show types a warning before the review.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{Accounts, LaunchFixture, TestAutolaunchTreasuryChainClient, TestSupport}
  alias Autolaunch.Actors.{Human, System}

  @aapl "0xb200000000000000000000c2e324d24d7eecd1fb"
  @route "0x547f3b931eaf75bab98364ab396058ddc2e68e4a"

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:autolaunch, :prelaunch_read_only)
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.put_env(:autolaunch, :prelaunch_read_only, previous) end)
  end

  test "Review launch puts the review in the form's place and Continue Editing brings the form back",
       %{conn: conn} do
    LaunchFixture.install()
    setup = LaunchFixture.actor()
    TestAutolaunchTreasuryChainClient.seed_verified!(LaunchFixture.treasury())
    session = signed_in_session(setup[:account].id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/agent-business")

    render_async(view)
    waive_connections(view)

    card = "#autolaunch-launch-wallet-#{setup[:draft].id}"
    side = "#{card}-side"

    # Before the review: the card's button sits beside the form, and the card
    # itself takes no room in the form's place.
    assert has_element?(view, ".create-page__main > #{card}[hidden]")
    refute has_element?(view, "#launch-transactions .launch-wallet-review")
    assert view |> element(side) |> render() =~ ~s(phx-click="review_launch")

    view |> with_target(card) |> render_hook("onchain_active_wallet", %{address: setup[:wallet]})
    view |> with_target(card) |> render_hook("review_launch", %{})

    # The review is open in the form's place, its wallet button last inside it,
    # and the button beside it now takes the review away.
    assert has_element?(view, ".create-page__main > #{card}:not([hidden])")
    assert has_element?(view, "#{card} .launch-wallet-review:not([hidden])", "Open Research")

    assert view
           |> element("#{card} .launch-wallet-review > [data-onchain-step]:last-child")
           |> render() =~ "Create the launch"

    side_html = view |> element(side) |> render()
    assert side_html =~ "Continue Editing"
    assert side_html =~ ~s(phx-click="cancel_review")
    refute side_html =~ ~s(phx-click="review_launch")

    view |> with_target(card) |> render_hook("cancel_review", %{})

    # Back to the form, with every value as it was.
    assert has_element?(view, ".create-page__main > #{card}[hidden]")

    assert has_element?(
             view,
             ~s(#launch-token-details-name[value="Open Research"])
           )

    assert has_element?(view, ~s(#launch-token-details-symbol[value="OPEN"]))
    assert view |> element(side) |> render() =~ ~s(phx-click="review_launch")
  end

  test "the needed line and Review launch follow the field typed last, in the same change",
       %{conn: conn} do
    account =
      Accounts.register_verified!(
        "did:privy:create-review:#{Elixir.System.unique_integer([:positive])}",
        LaunchFixture.wallet(),
        [LaunchFixture.wallet()],
        actor: %System{}
      )

    Autolaunch.record_stock_admission!(
      %{
        chain_id: 8453,
        address: @aapl,
        symbol: "AAPLc",
        name: "Apple Inc.",
        decimals: 8,
        route: @route,
        admitted: true
      },
      actor: %System{}
    )

    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/create")

    view
    |> form("#stocks-token-details", stock_draft: %{name: "Apple Pair", symbol: "aplp"})
    |> render_submit()

    actor = %Human{human_account_id: account.id}
    {:ok, draft} = Autolaunch.get_my_stocks_launch_draft(actor: actor)

    {:ok, _attached} =
      Autolaunch.Stocks.LaunchDraftImageStorage.store_and_attach(
        draft,
        File.read!("test/support/fixtures/launch-draft.png"),
        "image/png",
        "launch.png",
        actor
      )

    # Choosing the stock saves it and picks the stored picture up.
    view
    |> form("#stocks-terms", stock_draft: %{stock_address: @aapl})
    |> render_change()

    assert view |> element(".create-page__need") |> render() =~ "description"

    # The description is typed and not yet saved: the page follows it at once.
    html =
      view
      |> form("#stocks-token-details", stock_draft: %{description: "Pair"})
      |> render_change()

    {:ok, saved} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
    assert saved.description in [nil, ""]

    refute has_element?(view, ".create-page__need")
    assert html =~ ~s(id="autolaunch-stocks-launch-wallet-#{draft.id}")

    # Cleared again, the description is needed again, in that same change.
    view
    |> form("#stocks-token-details", stock_draft: %{description: ""})
    |> render_change()

    assert view |> element(".create-page__need") |> render() =~ "description"

    # Leaving the field saves what it holds.
    view
    |> element("#stocks-token-details-description")
    |> render_blur(%{value: "Pair"})

    {:ok, saved} = Autolaunch.get_my_stocks_launch_draft(actor: actor)
    assert saved.description == "Pair"
    refute has_element?(view, ".create-page__need")
  end

  test "Revstake's needed line and Review launch follow the field typed last, in the same change",
       %{conn: conn} do
    {view, setup} =
      revstake(conn, %{"description" => nil, "treasury" => nil, "treasury_path" => "contract"})

    treasury = LaunchFixture.treasury()
    needed = view |> element(".create-page__need") |> render()
    assert needed =~ "description"
    assert needed =~ "treasury"

    # The description is typed and not yet saved: the page follows it at once.
    view
    |> form("#launch-token-details", launch_draft: %{description: "Open work"})
    |> render_change()

    needed = view |> element(".create-page__need") |> render()
    refute needed =~ "description"
    assert needed =~ "treasury"

    # The treasury typed last: nothing is needed and Review launch opens, before
    # either field is saved.
    view
    |> form("#launch-treasury-details", launch_draft: %{treasury: treasury})
    |> render_change()

    {:ok, saved} = Autolaunch.get_my_account_launch_draft(actor: setup[:actor])
    assert saved.description in [nil, ""]
    assert saved.treasury in [nil, ""]

    refute has_element?(view, ".create-page__need")
    waive_connections(view)

    assert view
           |> element("#autolaunch-launch-wallet-#{setup[:draft].id}-side")
           |> render() =~ ~s(phx-click="review_launch")

    # Cleared again, the treasury is needed again, in that same change.
    view
    |> form("#launch-treasury-details", launch_draft: %{treasury: ""})
    |> render_change()

    assert view |> element(".create-page__need") |> render() =~ "treasury"

    # Leaving each field saves what it holds.
    view
    |> element("#launch-token-details-description")
    |> render_blur(%{value: "Open work"})

    view
    |> element("#launch-treasury-details-treasury")
    |> render_blur(%{value: treasury})

    {:ok, saved} = Autolaunch.get_my_account_launch_draft(actor: setup[:actor])
    assert saved.description == "Open work"
    assert saved.treasury == treasury
    refute has_element?(view, ".create-page__need")
  end

  test "a Revstake field whose save was refused keeps its text and mark while another field saves",
       %{conn: conn} do
    {view, setup} = revstake(conn, %{})

    view
    |> element("#launch-token-details-symbol")
    |> render_blur(%{value: "AB$"})

    assert has_element?(view, "#launch-token-details-symbol-error")

    view
    |> element("#launch-token-details-description")
    |> render_blur(%{value: "Still open"})

    {:ok, saved} = Autolaunch.get_my_account_launch_draft(actor: setup[:actor])
    assert saved.description == "Still open"
    assert saved.symbol == "OPEN"
    assert has_element?(view, ~s(#launch-token-details-symbol[value="AB$"]))
    assert has_element?(view, "#launch-token-details-symbol-error")
  end

  for {said, providers, asked?} <- [
        {"no X, GitHub or ENS account on show types a warning before Review launch", [], true},
        {"a checked X account on show is not asked for the warning", [:x], false},
        {"GitHub on show is not asked for the warning", [:github], false},
        {"ENS on show is not asked for the warning", [:ens], false}
      ] do
    test "a Revstake creator with #{said}", %{conn: conn} do
      LaunchFixture.install()
      TestAutolaunchTreasuryChainClient.seed_verified!(LaunchFixture.treasury())
      setup = LaunchFixture.actor()
      for provider <- unquote(providers), do: TestSupport.connect!(setup[:account], provider)
      session = signed_in_session(setup[:account].id)

      {:ok, view, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(session)
        |> connects_with(session)
        |> live("/agent-business")

      render_async(view)
      assert has_element?(view, "#launch-no-connections") == unquote(asked?)
    end
  end

  # The Revstake page, signed in, for a saved draft with `draft` fields replaced.
  defp revstake(conn, draft) do
    LaunchFixture.install()
    setup = LaunchFixture.actor(draft: draft)
    session = signed_in_session(setup[:account].id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/agent-business")

    render_async(view)
    {view, setup}
  end

  defp waive_connections(view) do
    view
    |> form("#launch-no-connections-form", %{
      "typed" =>
        "I realize my Revstake auction may not appear in the gallery or list, because reputation and social proof are important for raising initial funds for an agent"
    })
    |> render_submit()
  end
end
