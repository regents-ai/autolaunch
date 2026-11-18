defmodule AutolaunchWeb.BidOpeningTest do
  @moduledoc """
  Before the chain's latest block reaches an auction's start block a bid is
  certain to fail, so the bid panel's button is disabled and counts down to
  when that block is due; once the chain says bidding is open it places bids
  again (rule 11). Other refusals leave the button pressable.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Phoenix.LiveViewTest

  alias Autolaunch.{BaseRpcStub, LabAbi}
  alias Phoenix.LiveView.AsyncResult

  @start_block 10_000
  @not_open_address "0x4444444444444444444444444444444444444444"

  setup :bidder

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
        module={AutolaunchWeb.BidComponent}
        id="bid"
        auction={@auction}
        book={AsyncResult.ok(%{clearing_q96: 0, clearing: "0", price_to_beat: nil, block: 30_000_000})}
        preset_amount="1"
        preset_limit="3"
        authenticated
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  defp latest(number) do
    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x" <> Integer.to_string(number, 16),
          "hash" => "0x" <> String.duplicate("cd", 32),
          "timestamp" => "0x" <> Integer.to_string(System.os_time(:second), 16)
        }
      }
    })
  end

  defp panel(conn, account, auction, wallet) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Panel,
        session: %{"auction" => auction, "account_id" => account.id}
      )

    render_hook(with_target(view, "#bid"), "onchain_active_wallet", %{"address" => wallet})
    render_async(view)
    view
  end

  test "the button counts down, disabled, until the start block, then places the bid",
       %{conn: conn, account: account, wallet: wallet} do
    install()
    start = LabAbi.selector("startBlock()")

    BaseRpcStub.install(:autolaunch_lab_http_client, fn
      %{data: ^start}, _state -> BaseRpcStub.uint(@start_block)
      _call, _state -> "0x"
    end)

    # 1,500 blocks of 0.2 seconds: the start block is due in five minutes.
    latest(@start_block - 1_500)

    auction =
      Autolaunch.TestSupport.project_auction(
        address: @not_open_address,
        title: "Not open yet",
        featured: false,
        state: :created
      )
      |> Autolaunch.set_auction_bid_terms!(@not_open_address, regent(), "REGENT", 18, "2.5",
        actor: system()
      )

    view = panel(conn, account, auction, wallet)
    due = System.os_time(:millisecond) + 300_000

    [opens_at] =
      view
      |> element("#bid-opens[disabled]")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("data-opens-at")

    assert_in_delta String.to_integer(opens_at), due, 5_000
    refute has_element?(view, "#bid .token-swap__wallet-step")
    assert has_element?(view, "#bid-notice[hidden]")

    # The block arrives: at zero the countdown asks for a new read, and the
    # chain says bidding is open.
    latest(@start_block)
    render_hook(with_target(view, "#bid"), "opening_due", %{})
    render_async(view)

    refute has_element?(view, "#bid-opens")
    assert has_element?(view, "#bid .token-swap__wallet-step[data-onchain-step]:not([disabled])")
  end

  # A bid sent at the latest block lands in the next one at the earliest, and
  # the auction takes bids from its start block on.
  test "two blocks before the start the button counts down to the next block; the block before the start it places the bid, which lands in the start block",
       %{conn: conn, account: account, wallet: wallet} do
    install()
    start = LabAbi.selector("startBlock()")

    BaseRpcStub.install(:autolaunch_lab_http_client, fn
      %{data: ^start}, _state -> BaseRpcStub.uint(@start_block)
      _call, _state -> "0x"
    end)

    latest(@start_block - 2)

    auction =
      Autolaunch.TestSupport.project_auction(
        address: @not_open_address,
        title: "Not open yet",
        featured: false,
        state: :created
      )
      |> Autolaunch.set_auction_bid_terms!(@not_open_address, regent(), "REGENT", 18, "2.5",
        actor: system()
      )

    view = panel(conn, account, auction, wallet)

    # One block of 0.2 seconds to go.
    [opens_at] =
      view
      |> element("#bid-opens[disabled]")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.attribute("data-opens-at")

    assert_in_delta String.to_integer(opens_at), System.os_time(:millisecond) + 200, 1_500
    refute has_element?(view, "#bid .token-swap__wallet-step")

    latest(@start_block - 1)
    render_hook(with_target(view, "#bid"), "opening_due", %{})
    render_async(view)

    refute has_element?(view, "#bid-opens")
    assert has_element?(view, "#bid .token-swap__wallet-step[data-onchain-step]:not([disabled])")
  end

  test "an open auction's refusal leaves the button pressable",
       %{conn: conn, account: account, auction: auction, wallet: wallet} do
    # No treasury report is recorded, so the bid is refused.
    install()
    BaseRpcStub.install(:autolaunch_lab_http_client, fn _call, _state -> "0x" end)

    view = panel(conn, account, auction, wallet)

    refute has_element?(view, "#bid-opens")
    assert has_element?(view, "#bid-notice:not([hidden])")
    assert has_element?(view, "#bid .token-swap__wallet-step:not([disabled]):not([hidden])")
  end
end
