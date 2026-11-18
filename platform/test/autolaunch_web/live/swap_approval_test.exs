defmodule AutolaunchWeb.SwapApprovalTest do
  @moduledoc """
  The swap panel moves on once each approval lands, even one its wallet sent
  from a review the panel had already built again. The panel builds its review
  again as soon as an approval lands, and a person who pressed the next
  approval meanwhile, and confirmed it in the wallet only afterwards, reports
  it against the review it was sent from. Once that approval lands too, the
  review on the page asks only for the swap (onchain-buttons, rules 1 and 6).
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, StakeChain}

  @token_hash "0x" <> String.duplicate("a", 64)
  @permit2_hash "0x" <> String.duplicate("b", 64)
  @regent 5 * 10 ** 18

  setup :bidder

  setup do
    # The site as it runs once launches are open, when the form is offered. A
    # landed step then asks the chain's readers to read it again, which queues
    # their jobs; no queue runs under ExUnit.
    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    on_exit(fn -> Application.delete_env(:autolaunch, :prelaunch_read_only) end)

    start_supervised!(
      {Oban,
       AshOban.config(
         Application.fetch_env!(:autolaunch, :ash_domains),
         Application.fetch_env!(:autolaunch, Oban)
       )}
    )

    :ok
  end

  # The swap panel as the token page holds it, for the signed-in wallet,
  # buying `Autolaunch.StakeChain`'s Revstake token with REGENT.
  defmodule Panel do
    use Phoenix.LiveView

    def mount(_params, %{"auction" => auction, "account_id" => account_id}, socket) do
      {:ok,
       assign(socket,
         auction: auction,
         account_id: account_id,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.SwapComponent}
        id="swap"
        launch={%{chain: :base, auction: @auction}}
        symbol="LRVS"
        currency="REGENT"
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  test "an approval sent from the review the panel replaced still moves it on to the swap once it lands",
       %{conn: conn, account: account, wallet: wallet} do
    auction =
      Autolaunch.TestSupport.project_auction(
        chain_id: 8453,
        state: :graduated,
        symbol: "LRVS",
        token_address: StakeChain.subject()
      )

    # The wallet holds REGENT and has approved nothing yet.
    StakeChain.install(balance: @regent, swap_quote: 4 * 10 ** 18)
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel,
        session: %{"auction" => auction, "account_id" => account.id}
      )

    panel = with_target(view, "#swap")
    render_hook(panel, "onchain_active_wallet", %{"address" => wallet})
    render_async(view)
    view |> form("#swap form") |> render_submit(%{amount: "1"})

    assert_push_event(view, "onchain-steps:review", %{
      review: %{
        id: first_id,
        chain: %{chain_id: chain_id},
        steps: [
          %{step: "token_approval"} = token_approval,
          %{step: "permit2_approval"} = permit2_approval,
          %{step: "swap"}
        ]
      }
    })

    # The REGENT approval lands, and the pool's price has moved since, so the
    # review built again is a new one that still asks for the Permit2
    # approval, after the REGENT approval, done.
    StakeChain.put(balance: @regent, allowance: @regent, swap_quote: 3 * 10 ** 18)
    landed(@token_hash, wallet, chain_id, token_approval)

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "token_approval",
      "transaction_hash" => @token_hash
    })

    render_async(view)

    assert_push_event(view, "onchain-steps:review", %{
      review: %{
        id: second_id,
        steps: [%{step: "token_approval"}, %{step: "permit2_approval"}, %{step: "swap"}]
      }
    })

    assert second_id != first_id

    # The Permit2 approval was pressed from the first review before the second
    # one reached the page; the wallet reports it now, against the first.
    StakeChain.put(
      balance: @regent,
      allowance: @regent,
      permit2: %{amount: @regent, expiration: Integer.pow(2, 48) - 1},
      swap_quote: 3 * 10 ** 18
    )

    landed(@permit2_hash, wallet, chain_id, permit2_approval)

    render_hook(panel, "step_sent", %{
      "review_id" => first_id,
      "step" => "permit2_approval",
      "transaction_hash" => @permit2_hash
    })

    render_async(view)

    # Once it lands, the review on the page asks only for the swap.
    assert_push_event(view, "onchain-steps:review", %{
      review: %{steps: [%{step: "token_approval"}, %{step: "swap"}]}
    })

    assert has_element?(view, "#swap .token-swap__wallet-step[data-onchain-step=swap]")

    refute has_element?(
             view,
             "#swap .token-swap__wallet-step[data-onchain-step=permit2_approval]"
           )
  end

  # The chain holds `step`, sent from `wallet` as `hash`, and its receipt.
  defp landed(hash, wallet, chain_id, step) do
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
      receipts: %{hash => BaseRpcStub.receipt(hash, "0x21", [])}
    })
  end
end
