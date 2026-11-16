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

  alias Autolaunch.{Accounts, BaseRpcStub, EarnChain, TestSupport}

  @moduletag :capture_log
  alias AutolaunchWeb.EarnComponent
  alias RegentChain.{BuilderCode, Call}

  @unit EarnChain.unit()
  @panel "#earn-aave-usdc-panel"
  @review "#earn-aave-usdc-panel-review-panel"
  @hash "0x" <> String.duplicate("a", 64)

  test "the terms show the rate now, what is supplied and available, the capacity and the block read at",
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
    assert has_element?(view, "#earn-aave-usdc-terms div", "Capacity")
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

  test "a reading that fails says so and shows no figures, the panel stays, and Refresh reads again",
       %{conn: conn} do
    EarnChain.install(%{unreadable: true})
    {:ok, view, _html} = live(conn, "/earn")
    settled(view)

    assert has_element?(view, "#earn-aave-usdc .earn__note[role=alert]")
    refute has_element?(view, "#earn-aave-usdc-terms")
    assert has_element?(view, "#{@panel} button[data-account-target=sign-in]")

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

  test "a frozen market disables Deposit, and lets a withdrawal out up to the balance",
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

  test "a confirmed step reads the market and the wallet again on every open page, and the last one closes the review with the exact amount moved",
       %{conn: conn} do
    EarnChain.install(%{allowance: 251 * @unit})
    {:ok, other, _html} = live(build_conn(), "/earn")
    settled(other)

    {view, panel, wallet} = signed_in(conn)
    review(view, "250.123457")

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: review_id, chain: %{chain_id: chain_id}, steps: [_approval, supply]}
    })

    # The review gives the amount to the unit, not the shortened figure.
    assert has_element?(view, @review, "250.123457 USDC")

    # The deposit lands: the wallet's USDC is in the market.
    EarnChain.put(%{
      balance: 250_123_457,
      usdc: 749_876_543,
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

    assert has_element?(view, "#earn-done", "250.123457 USDC")
    assert has_element?(view, "#{@review}[hidden]")
    assert has_element?(view, "#{@panel}-amount[value='']")
    assert has_element?(view, "#{@panel}-balance", usdc(250_123_457))
    assert has_element?(view, "#{@panel}-balance", usdc(749_876_543))
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(300_000_250 * @unit))

    # Another visitor's page reads the market again too.
    settled(other)
    assert has_element?(other, "#earn-aave-usdc-terms", usdc(300_000_250 * @unit))
  end

  test "a step that does not go through is reviewed again from the chain as it is now",
       %{conn: conn} do
    EarnChain.install(%{allowance: 250 * @unit})
    {view, panel, wallet} = signed_in(conn)
    review(view, "250")

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: first, chain: %{chain_id: chain_id}, steps: [_approval, supply]}
    })

    # The supply reverts with the chain unchanged: the same deposit is built
    # again as a new review, and the press note says to press again.
    reverted(panel, first, supply, wallet, chain_id, "a")
    settled(view)

    assert_push_event(view, "onchain-steps:review", %{review: nil})

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: second, steps: [_approval_again, supply_again]}
    })

    assert second != first
    assert has_element?(view, "#{@review}:not([hidden])", "press again to send it")

    # It reverts again after the wallet's USDC moved elsewhere: nothing is
    # built, the review closes and the button says why.
    EarnChain.put(%{allowance: 250 * @unit, usdc: 100 * @unit})
    reverted(panel, second, supply_again, wallet, chain_id, "b")
    settled(view)

    assert_push_event(view, "onchain-steps:review", %{review: nil})
    refute_push_event(view, "onchain-steps:review", %{review: %{}})
    assert has_element?(view, "#{@review}[hidden]")

    assert has_element?(
             view,
             "#{@panel}-notice",
             "The step did not go through and nothing moved. Not enough USDC on Base."
           )

    assert has_element?(view, "#{@panel}-review[disabled]")
  end

  test "a paused or closed market disables both steps with the reason, and Refresh reads the panel again",
       %{conn: conn} do
    EarnChain.install(%{paused: true, balance: 40 * @unit})
    {view, _panel, _wallet} = signed_in(conn)

    assert has_element?(view, "#earn-aave-usdc .earn__status[data-status=paused]")
    type(view, "10")
    assert has_element?(view, "#{@panel}-review[disabled]")
    assert has_element?(view, "#{@panel}-why", "This market is paused")

    view |> element("nav.earn__tabs a", "Withdraw") |> render_click()
    type(view, "10")
    assert has_element?(view, "#{@panel}-review[disabled]")
    assert has_element?(view, "#{@panel}-why", "This market is paused")

    # The market is closed meanwhile: Refresh reads the market and the panel's preview.
    EarnChain.put(%{active: false, balance: 40 * @unit})
    view |> element("#earn-read-again") |> render_click()
    settled(view)

    assert has_element?(view, "#earn-aave-usdc .earn__status[data-status=inactive]")
    assert has_element?(view, "#{@panel}-review[disabled]")
    assert has_element?(view, "#{@panel}-why", "This market is closed")

    # It opens again: the next Refresh brings the button back.
    EarnChain.put(%{balance: 40 * @unit})
    view |> element("#earn-read-again") |> render_click()
    settled(view)

    refute has_element?(view, "#{@panel}-review[disabled]")
  end

  test "signed in, the panel works while the market can't be read, and says why a preview couldn't be had",
       %{conn: conn} do
    EarnChain.install(%{unreadable: true})
    {view, _panel, _wallet} = signed_in(conn)

    assert has_element?(view, "#earn-aave-usdc .earn__note[role=alert]")
    type(view, "10")

    assert has_element?(view, "#{@panel} .earn-panel__problem[role=alert]")
    refute has_element?(view, "#{@panel}-review[disabled]")
  end

  test "a step heard of from another of the site's machines is counted here before the page reads",
       %{conn: conn} do
    EarnChain.install()
    Application.put_env(:autolaunch, :earn_terms_kept_ms, 60_000)
    {:ok, _cleared} = Cachex.clear(Autolaunch.Earn.SharedTerms.cache())

    on_exit(fn ->
      Application.put_env(:autolaunch, :earn_terms_kept_ms, 0)
      Cachex.clear(Autolaunch.Earn.SharedTerms.cache())
    end)

    {:ok, view, _html} = live(conn, "/earn")
    settled(view)

    # The step lands on another machine: this one keeps its reading from
    # before it, and hears of it only as the message every page gets.
    EarnChain.put(%{supplied: 300_000_250 * @unit})

    Phoenix.PubSub.broadcast(
      Autolaunch.PubSub,
      "earn:aave-usdc",
      {:earn_changed, "aave-usdc", @hash}
    )

    settled(view)
    assert has_element?(view, "#earn-aave-usdc-terms", usdc(300_000_250 * @unit))
  end

  test "a new reading drops the reason that held the button, so it can be pressed until the chain answers again",
       %{conn: conn} do
    EarnChain.install(%{usdc: 100 * @unit})
    {view, _panel, _wallet} = signed_in(conn)

    type(view, "250")
    assert has_element?(view, "#{@panel}-review[disabled]")

    # Refresh: the market, the preview and the wallet are each read again,
    # and none has answered yet.
    EarnChain.put(%{usdc: 100 * @unit, hold: self()})
    view |> element("#earn-read-again") |> render_click()
    readers = held(3)
    EarnChain.put(%{usdc: 100 * @unit})

    refute has_element?(view, "#{@panel}-review[disabled]")
    assert view |> element("#{@panel}-why") |> render() |> words() == ""

    Enum.each(readers, &send(&1, :go))
    settled(view)
    assert has_element?(view, "#{@panel}-review[disabled]")
  end

  test "the page drawn again with nothing new for the panel reads nothing again", %{conn: conn} do
    EarnChain.install()
    {view, _panel, _wallet} = signed_in(conn)
    type(view, "10")

    EarnChain.put(%{hold: self()})
    view |> element("#earn-read-again") |> render_click()
    readers = held(3)

    # The market's reading arrives and the page draws the panel again, its
    # amount, wallet, tab and readings as they were.
    Enum.each(readers, &send(&1, :go))
    refute_receive {:earn_chain_held, _again}, 300

    EarnChain.put(%{})
    settled(view)
    assert has_element?(view, "#earn-aave-usdc-terms", "4.68%")
    refute has_element?(view, "#{@panel}-review[disabled]")
  end

  test "a step reported again, or checked again while it is still being read, starts no second check",
       %{conn: conn} do
    EarnChain.install(%{allowance: 250 * @unit})
    {view, panel, wallet} = signed_in(conn)
    review(view, "250")

    assert_push_event(view, "onchain-steps:review", %{
      review: %{id: review_id, chain: %{chain_id: chain_id}, steps: [_approval, supply]}
    })

    # Sent, and not yet in a block.
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
      }
    })

    sent = %{"review_id" => review_id, "step" => "supply", "transaction_hash" => @hash}
    # The first check reads the transaction, then its receipt, which isn't there.
    render_hook(panel, "step_sent", sent)
    assert_receive {:rpc, "eth_getTransactionReceipt", [@hash]}
    assert_received {:rpc, "eth_getTransactionByHash", [@hash]}

    # The next read waits two seconds: anything sooner is a second check.
    render_hook(panel, "step_sent", sent)
    render_hook(panel, "step_sent", %{sent | "transaction_hash" => String.upcase(@hash)})
    render_hook(panel, "check_again", %{"hash" => @hash})
    refute_receive {:rpc, _method, [@hash]}, 500

    assert has_element?(view, "#{@review}-supply[data-state=sent]")
  end

  test "Refresh pressed while the market is being read starts no second reading", %{conn: conn} do
    EarnChain.install()
    {:ok, view, _html} = live(conn, "/earn")
    settled(view)

    EarnChain.put(%{hold: self()})
    view |> element("#earn-read-again") |> render_click()
    assert_receive {:earn_chain_held, reading}

    view |> element("#earn-read-again") |> render_click()
    refute_receive {:earn_chain_held, _another}, 100

    send(reading, :go)
    settled(view)
    assert has_element?(view, "#earn-aave-usdc-terms", "4.68%")
  end

  test "another wallet starts from an empty amount with Max off", %{conn: conn} do
    EarnChain.install(%{balance: 40 * @unit})
    nonce = System.unique_integer([:positive])

    [first, second] =
      for n <- [1, 2],
          do: "0x" <> String.pad_leading(Integer.to_string(nonce * 10 + n, 16), 40, "0")

    account =
      Accounts.register_verified!("did:privy:earn-wallets:#{nonce}", first, [first, second],
        actor: %Autolaunch.Actors.System{}
      )

    {view, panel, _wallet} = signed_in(conn, "/earn?tab=withdraw", true, account)

    view |> element("#{@panel}-max") |> render_click()
    settled(view)
    assert has_element?(view, "#{@panel}-max[aria-pressed=true]")

    render_hook(panel, "onchain_active_wallet", %{"address" => second})
    settled(view)
    assert has_element?(view, "#{@panel}-amount[value='']")
    assert has_element?(view, "#{@panel}-max[aria-pressed=false]")

    type(view, "12")
    render_hook(panel, "onchain_active_wallet", %{"address" => first})
    settled(view)
    assert has_element?(view, "#{@panel}-amount[value='']")
  end

  test "a change with no amount, or a check of a hash that is not text, leaves the panel as it is",
       %{conn: conn} do
    EarnChain.install()
    {view, panel, _wallet} = signed_in(conn)
    type(view, "10")

    render_hook(panel, "change", %{})
    render_hook(panel, "check_again", %{"hash" => 7})
    render_hook(panel, "check_again", %{})
    settled(view)

    assert has_element?(view, "#{@panel}-amount[value='10']")
    refute has_element?(view, "#{@panel}-review[disabled]")
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

  # The wallet sent `step` of review `id`, and the chain mined it reverted.
  defp reverted(panel, id, step, wallet, chain_id, digit) do
    hash = "0x" <> String.duplicate(digit, 64)

    BaseRpcStub.put(%{
      transactions: %{
        hash => %{
          "hash" => hash,
          "chainId" => "0x" <> Integer.to_string(chain_id, 16),
          "from" => wallet,
          "to" => step.to,
          "input" => step.data,
          "value" => "0x0"
        }
      },
      receipts: %{hash => BaseRpcStub.receipt(hash, "0x20", [], "0x0")}
    })

    render_hook(panel, "step_sent", %{
      "review_id" => id,
      "step" => step.step,
      "transaction_hash" => hash
    })
  end

  # The `count` reads of the market the double holds, each waiting for `:go`.
  defp held(count) do
    for _read <- 1..count do
      assert_receive {:earn_chain_held, reader}
      reader
    end
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

  # A signed-in person at `path`, a new one unless `account` is given, their
  # first wallet open unless `open?` is false.
  defp signed_in(conn, path \\ "/earn", open? \\ true, account \\ TestSupport.register_creator!()) do
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
