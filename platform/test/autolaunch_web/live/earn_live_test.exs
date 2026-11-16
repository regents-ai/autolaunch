defmodule AutolaunchWeb.EarnLiveTest do
  @moduledoc """
  `/earn` shows the market's terms read at the latest block with that block
  named, and its wallet panel works as covered calls' panels do: the button
  reviews the amount as it stands and opens the wallet steps over the panel,
  it is disabled only when the chain makes the step certain to fail, with the
  reason beside it, and a confirmed step reads the market and the wallet again.
  The chain is the Earn double (`Autolaunch.EarnChain`).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, EarnChain, TestSupport}

  @moduletag :capture_log
  alias AutolaunchWeb.EarnComponent
  alias RegentChain.{BuilderCode, Call}

  @unit EarnChain.unit()
  @panel "#earn-aave-usdc-panel"
  @review "#earn-aave-usdc-panel-review-panel"
  @hash "0x" <> String.duplicate("a", 64)

  test "the terms show the rate now, what is supplied and available, the room and the block read at",
       %{conn: conn} do
    EarnChain.install(%{supplied: 900 * @unit, scaled: 900 * @unit, cap: 1_000, accrued: 0})

    # The first load shows no figures: the market is read once the page connects.
    first = conn |> get("/earn") |> html_response(200) |> LazyHTML.from_document()
    assert Enum.any?(LazyHTML.query(first, "#earn-aave-usdc .earn__waiting[aria-busy=true]"))
    refute Enum.any?(LazyHTML.query(first, "#earn-aave-usdc-terms"))

    {:ok, view, _html} = live(conn, "/earn")
    settled(view)

    assert has_element?(view, "#earn-aave-usdc-terms .earn__rate", "4.68%")
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(900 * @unit))
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(50_000_000 * @unit))
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(100 * @unit))
    assert has_element?(view, "#earn-aave-usdc .earn__status[data-status=open]")
    assert has_element?(view, "#earn-aave-usdc .earn__block", "Read at block 32")

    # Signed out, the panel asks for a sign-in and shows no balance.
    assert has_element?(view, "#{@panel} button[data-account-target=sign-in]")
    refute has_element?(view, "#{@panel}-balance")
    refute has_element?(view, "#{@panel}-review")
  end

  test "a market at its cap reads full, and one without a cap says so", %{conn: conn} do
    EarnChain.install(%{supplied: 1_000 * @unit, scaled: 1_000 * @unit, cap: 1_000})
    {:ok, view, _html} = live(conn, "/earn")
    settled(view)
    assert has_element?(view, "#earn-aave-usdc-terms", "Full")

    EarnChain.put(%{})
    view |> element("#earn-read-again") |> render_click()
    settled(view)
    assert has_element?(view, "#earn-aave-usdc-terms", "No cap")
  end

  test "a reading that fails says so and shows no figures, and Refresh reads again", %{conn: conn} do
    EarnChain.install(%{unreadable: true})
    {:ok, view, _html} = live(conn, "/earn")
    settled(view)

    assert has_element?(view, "#earn-aave-usdc .earn__note[role=alert]")
    refute has_element?(view, "#earn-aave-usdc-terms")
    refute has_element?(view, @panel)

    EarnChain.put(%{})
    view |> element("#earn-read-again") |> render_click()
    settled(view)

    refute has_element?(view, "#earn-aave-usdc .earn__note[role=alert]")
    assert has_element?(view, "#earn-aave-usdc-terms", "4.68%")
  end

  test "signed in with a wallet open, the panel shows the balance and the wallet's USDC; Max fills them",
       %{conn: conn} do
    EarnChain.install(%{balance: 40 * @unit, usdc: 1_000 * @unit})
    {view, _panel, _wallet} = signed_in(conn)

    assert has_element?(view, "#{@panel}-balance", usdc(40 * @unit))
    assert has_element?(view, "#{@panel}-balance", usdc(1_000 * @unit))

    view |> element("#{@panel}-max") |> render_click()
    assert has_element?(view, "#{@panel}-amount[value='1000']")
    assert has_element?(view, "#{@panel}-max[aria-pressed=false]")
  end

  test "with nothing lent yet the panel says so", %{conn: conn} do
    EarnChain.install()
    {view, _panel, _wallet} = signed_in(conn)

    assert has_element?(view, "#{@panel} .earn-panel__muted", "No balance yet")
  end

  test "Deposit reviews the exact USDC approval, then the supply to the wallet, each with the Builder Code",
       %{conn: conn} do
    EarnChain.install()
    {view, _panel, wallet} = signed_in(conn)

    assert has_element?(view, "#{@review}[hidden]")
    review(view, "250")

    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [approval, supply]}})

    assert {approval.step, String.downcase(approval.to)} == {"usdc_approval", EarnChain.usdc()}

    assert BuilderCode.call(approval.data) ==
             Call.encode("approve(address,uint256)", [EarnChain.pool(), 250 * @unit])

    assert {supply.step, String.downcase(supply.to)} == {"supply", EarnChain.pool()}

    assert BuilderCode.call(supply.data) ==
             Call.encode("supply(address,uint256,address,uint16)", [
               EarnChain.usdc(),
               250 * @unit,
               wallet,
               0
             ])

    refute has_element?(view, "#{@review}[hidden]")
    assert has_element?(view, "#{@review}-usdc_approval[data-state=ready]")
    assert has_element?(view, "#{@review}-supply[data-state=ready]")

    render_click(element(view, "#{@review} button[aria-label=Close]"))
    assert has_element?(view, "#{@review}[hidden]")
  end

  test "an approval the chain holds for the amount shows as done; one for less does not",
       %{conn: conn} do
    EarnChain.install(%{allowance: 250 * @unit})
    {view, _panel, _wallet} = signed_in(conn)

    review(view, "250")
    assert has_element?(view, "#{@review}-usdc_approval[data-state=done]")
    assert has_element?(view, "#{@review}-supply[data-state=ready]")

    render_click(element(view, "#{@review} button[aria-label=Close]"))
    review(view, "250.000001")
    assert has_element?(view, "#{@review}-usdc_approval[data-state=ready]")
  end

  test "a deposit past the wallet's USDC is disabled with the reason, and comes back once the chain allows it",
       %{conn: conn} do
    EarnChain.install(%{usdc: 100 * @unit})
    {view, panel, _wallet} = signed_in(conn)

    type(view, "250")
    assert has_element?(view, "#{@panel}-review[disabled]")
    assert view |> element("#{@panel}-why") |> render() |> words() != ""

    # The wallet is topped up elsewhere; the panel reads the chain again.
    EarnChain.put(%{usdc: 1_000 * @unit})
    render_hook(panel, "refresh_funds", %{})
    settled(view)

    refute has_element?(view, "#{@panel}-review[disabled]")
    assert view |> element("#{@panel}-why") |> render() |> words() == ""
  end

  test "each blocked reason disables its button: a frozen market takes no deposit, and lets a withdrawal out",
       %{conn: conn} do
    EarnChain.install(%{frozen: true, balance: 40 * @unit})
    {view, _panel, _wallet} = signed_in(conn)

    type(view, "10")
    assert has_element?(view, "#{@panel}-review[disabled]")

    view |> element("nav.earn__tabs a", "Withdraw") |> render_click()
    settled(view)
    type(view, "10")
    refute has_element?(view, "#{@panel}-review[disabled]")

    type(view, "41")
    assert has_element?(view, "#{@panel}-review[disabled]")
  end

  test "Max on Withdraw asks for everything; a typed figure equal to the balance is that figure only",
       %{conn: conn} do
    EarnChain.install(%{balance: 40 * @unit})
    {view, _panel, wallet} = signed_in(conn, "/earn?tab=withdraw")

    review(view, "40")
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [typed]}})

    assert BuilderCode.call(typed.data) ==
             Call.encode("withdraw(address,uint256,address)", [
               EarnChain.usdc(),
               40 * @unit,
               wallet
             ])

    render_click(element(view, "#{@review} button[aria-label=Close]"))
    view |> element("#{@panel}-max") |> render_click()
    settled(view)
    assert has_element?(view, "#{@panel}-max[aria-pressed=true]")
    assert has_element?(view, "#{@panel}-amount[value='40']")
    view |> element("#{@panel}-form") |> render_submit(%{"amount" => "40"})

    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [everything]}})

    assert BuilderCode.call(everything.data) ==
             Call.encode("withdraw(address,uint256,address)", [
               EarnChain.usdc(),
               2 ** 256 - 1,
               wallet
             ])

    # Editing the figure Max filled in makes it that figure only.
    render_click(element(view, "#{@review} button[aria-label=Close]"))
    type(view, "4")
    review(view, "40")
    assert has_element?(view, "#{@panel}-max[aria-pressed=false]")
    assert_push_event(view, "onchain-steps:review", %{review: %{steps: [edited]}})
    assert BuilderCode.call(edited.data) == BuilderCode.call(typed.data)
  end

  test "a confirmed step reads the market and the wallet again, and the last one closes the review with what moved",
       %{conn: conn} do
    EarnChain.install(%{allowance: 250 * @unit})
    {view, panel, wallet} = signed_in(conn)
    review(view, "250")

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: review_id, chain: %{chain_id: chain_id}, steps: [_approval, supply]}
    })

    # The deposit lands: the wallet's USDC is in the market.
    EarnChain.put(%{
      balance: 250 * @unit,
      usdc: 750 * @unit,
      supplied: 300_000_250 * @unit,
      scaled: 300_000_250 * @unit
    })

    BaseRpcStub.put(%{
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "chainId" => "0x" <> Integer.to_string(chain_id, 16),
          "from" => wallet,
          "to" => supply.to,
          "input" => supply.data,
          "value" => "0x0"
        }
      },
      receipts: %{@hash => BaseRpcStub.receipt(@hash, "0x20", [])}
    })

    render_hook(panel, "step_sent", %{
      "review_id" => review_id,
      "step" => "supply",
      "transaction_hash" => @hash
    })

    settled(view)

    assert has_element?(view, "#earn-done")
    assert has_element?(view, "#{@review}[hidden]")
    assert has_element?(view, "#{@panel}-amount[value='']")
    assert has_element?(view, "#{@panel}-balance", usdc(250 * @unit))
    assert has_element?(view, "#{@panel}-balance", usdc(750 * @unit))
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(300_000_250 * @unit))
  end

  test "signed in with no wallet open, Deposit says so and opens nothing", %{conn: conn} do
    EarnChain.install()
    {view, _panel, _wallet} = signed_in(conn, "/earn", false)

    review(view, "50")

    assert has_element?(view, "#{@panel}-notice")
    assert has_element?(view, "#{@review}[hidden]")
    refute has_element?(view, "#{@panel}-review[disabled]")
  end

  test "an amount that doesn't read is said under the field, disables nothing and opens nothing",
       %{conn: conn} do
    EarnChain.install()
    {view, _panel, _wallet} = signed_in(conn)

    type(view, "1,000")
    assert view |> element("#{@panel}-entry") |> render() |> words() != ""
    refute has_element?(view, "#{@panel}-review[disabled]")

    review(view, "1,000")
    assert has_element?(view, "#{@panel}-notice")
    assert has_element?(view, "#{@review}[hidden]")
  end

  test "a review closes when the wallet that may act changes or the tab does", %{conn: conn} do
    EarnChain.install()
    {view, panel, wallet} = signed_in(conn)

    review(view, "10")
    refute has_element?(view, "#{@review}[hidden]")

    render_hook(panel, "onchain_active_wallet", %{"address" => "0x" <> String.duplicate("ab", 20)})

    settled(view)
    assert has_element?(view, "#{@review}[hidden]")

    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})
    review(view, "10")
    refute has_element?(view, "#{@review}[hidden]")

    view |> element("nav.earn__tabs a", "Withdraw") |> render_click()
    assert has_element?(view, "#{@review}[hidden]")
    assert has_element?(view, "#{@panel}-amount[value='']")
    assert has_element?(view, "#{@panel}-review", "Withdraw")
  end

  test "the portfolio shows the wallet's balance with Withdraw, and Refresh reads it again",
       %{conn: conn} do
    EarnChain.install(%{balance: 1})
    view = portfolio(conn)

    assert has_element?(view, "#portfolio-earn-aave-usdc-balance", usdc(1))
    assert has_element?(view, "#portfolio-earn-aave-usdc", "Read at block 32")
    assert has_element?(view, "#portfolio-earn-aave-usdc a[href='/earn?tab=withdraw']")

    EarnChain.put(%{balance: 40 * @unit})
    view |> element("#portfolio-read-again") |> render_click()
    render_async(view)
    assert has_element?(view, "#portfolio-earn-aave-usdc-balance", usdc(40 * @unit))
  end

  test "the portfolio offers Deposit with nothing lent, and says when a balance couldn't be read",
       %{conn: conn} do
    EarnChain.install()
    view = portfolio(conn)

    refute has_element?(view, "#portfolio-earn-aave-usdc a[href='/earn?tab=withdraw']")
    assert has_element?(view, "#portfolio-earn-aave-usdc a[href='/earn']")

    EarnChain.put(%{unreadable: true})
    view |> element("#portfolio-read-again") |> render_click()
    render_async(view)

    assert has_element?(view, "#portfolio-earn-aave-usdc-balance[role=alert]")
    refute has_element?(view, "#portfolio-earn-aave-usdc a")
  end

  test "signed out, the portfolio has no Earn section", %{conn: conn} do
    EarnChain.install(%{balance: 1})
    {:ok, view, _html} = live(conn, "/portfolio")
    render_async(view)

    refute has_element?(view, "#portfolio-earn")
  end

  # The signed-in portfolio, its Earn section read.
  defp portfolio(conn) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live("/portfolio")

    render_async(view)
    view
  end

  # The figure as every Earn amount shows it.
  defp usdc(units), do: EarnComponent.amount(units, 6, "USDC")

  # The amount typed into the panel, its figures read for it.
  defp type(view, amount) do
    view |> element("#{@panel}-form") |> render_change(%{"amount" => amount})
    settled(view)
  end

  # The amount typed, then the panel's button pressed with it.
  defp review(view, amount) do
    type(view, amount)
    view |> element("#{@panel}-form") |> render_submit(%{"amount" => amount})
  end

  # The page's reading, then the panel's, waited for.
  defp settled(view) do
    render_async(view)
    render_async(view)
    render_async(view)
  end

  # A new signed-in person at `path`, their one wallet open unless `open?` is false.
  defp signed_in(conn, path \\ "/earn", open? \\ true) do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live(path)

    settled(view)
    panel = with_target(view, @panel)

    if open?,
      do: render_hook(panel, "onchain_active_wallet", %{"address" => account.wallet_address})

    settled(view)
    {view, panel, String.downcase(account.wallet_address)}
  end

  defp words(html),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.split() |> Enum.join(" ")
end
