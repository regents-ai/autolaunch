defmodule AutolaunchWeb.RobinhoodBidSettlementPressTest do
  @moduledoc """
  A press on a Robinhood bid's return or claim before the row holds its review
  still reaches the wallet: the row prepares the settlement for the press and
  hands back its first step to send, as the Base card does
  (`AutolaunchWeb.BidSettlementPressTest`). One the auction could not answer
  keeps its button, so a later press asks the auction again.
  """
  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]
  import Phoenix.LiveViewTest

  alias Autolaunch.Actors.System
  alias Autolaunch.{BaseRpcStub, LabAbi}
  alias RegentChain.BuilderCode

  @chain_id 4_663
  @stock "0x2000000000000000000000000000000000000002"
  @bid_id 7
  @open "0x7777777777777777777777777777777777777777"
  @other "0x8888888888888888888888888888888888888888"

  setup :bidder

  setup do
    put_env(:autolaunch_robinhood_chain_id, @chain_id)

    put_env(
      :autolaunch_robinhood_deployment,
      Path.expand("../../fixtures/robinhood-deployment.json", __DIR__)
    )

    {:ok, _stock} =
      Autolaunch.record_stock_admission(
        %{
          chain_id: @chain_id,
          address: @stock,
          symbol: "TSLA",
          name: "Tesla",
          decimals: 18,
          route: "0x" <> String.duplicate("44", 20),
          feed: "0x" <> String.duplicate("55", 20),
          admitted: true
        },
        actor: %System{}
      )

    :ok
  end

  # The row as the bid panel holds it once bidding has ended, for the
  # signed-in owner of the bid.
  defmodule Row do
    use Phoenix.LiveView

    def mount(_params, %{"account_id" => account_id, "owner" => owner}, socket) do
      {:ok,
       assign(socket,
         account_id: account_id,
         owner: owner,
         lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account_id)
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={AutolaunchWeb.RobinhoodStockBidSettlementComponent}
        id="row"
        parent_id="bids"
        ended
        auction="0x3000000000000000000000000000000000000003"
        bid={%{"bid_id" => "7", "owner" => @owner, "exited_block" => "0", "tokens_filled_now" => "0"}}
        graduated?={false}
        token_symbol="RDOG"
        usd_rate={nil}
        stake_path={nil}
        current_human_id={@account_id}
        session_lease={@lease}
      />
      """
    end
  end

  # Robinhood as the settlement reads it, at one block: an auction that did
  # not reach its minimum, made by the deployment's launchpad, whose bid exits
  # with its whole amount and has nothing to claim.
  defmodule Robinhood do
    alias Autolaunch.{BaseRpcStub, BidFixture, LabAbi}
    alias Autolaunch.Robinhood.Lab

    @auction "0x3000000000000000000000000000000000000003"
    @stock "0x2000000000000000000000000000000000000002"
    @bid_id 7
    @q96 79_228_162_514_264_337_593_543_950_336

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", []), do: "0x1237"

    defp answer("eth_getBlockByNumber", ["latest", false]),
      do: %{
        "number" => "0x64",
        "hash" => "0x" <> String.duplicate("6c", 32),
        "timestamp" => "0x6700"
      }

    defp answer("eth_getCode", [@auction, _block]), do: "0x6000"

    defp answer("eth_call", [%{to: to, data: data}, _block]) do
      {:ok, config} = Lab.current()
      read(to == Lab.address!(config, :stocks_launchpad), to, String.slice(data, 0, 10))
    end

    # One simulated block: checkpoint, not graduated, the final price, nothing
    # raised, the exit returning the whole bid, and a claim the auction refuses.
    defp answer("eth_simulateV1", [%{blockStateCalls: [%{calls: [_, _, _, _, _, _]}]}, _block]),
      do: [
        %{
          "calls" => [
            ok("0x"),
            ok(uint(0)),
            ok(uint(2 * @q96)),
            ok(uint(0)),
            Map.put(ok("0x"), "logs", [bid_exited()]),
            %{"status" => "0x0", "returnData" => "0x", "logs" => []}
          ]
        }
      ]

    defp read(true, _launchpad, selector) do
      cond do
        selector == LabAbi.selector("launchIdOfAuction(address)") -> uint(1)
        selector == LabAbi.selector("stockAdmission(address)") -> words([1, 18, 1])
      end
    end

    defp read(false, @auction, selector) do
      cond do
        selector == LabAbi.selector("endBlock()") -> uint(90)
        selector == LabAbi.selector("claimBlock()") -> uint(95)
        selector == LabAbi.selector("currency()") -> words([number(@stock)])
        selector == LabAbi.selector("bids(uint256)") -> bid()
      end
    end

    # startBlock, startCumulativeMps, exitedBlock, maxPrice, owner, amountQ96, tokensFilled
    defp bid,
      do: words([10, 0, 0, 3 * @q96, number(BidFixture.wallet()), 12 * 10 ** 18 * @q96, 0])

    defp bid_exited,
      do: %{
        "address" => @auction,
        "topics" => [
          LabAbi.topic("BidExited(uint256,address,uint256,uint256)"),
          "0x" <> BaseRpcStub.hex_word(@bid_id),
          BaseRpcStub.address_topic(BidFixture.wallet())
        ],
        "data" => words([0, 12 * 10 ** 18])
      }

    defp ok(data), do: %{"status" => "0x1", "returnData" => data, "logs" => []}
    defp uint(value), do: BaseRpcStub.uint(value)
    defp words(values), do: "0x" <> Enum.map_join(values, &BaseRpcStub.hex_word/1)
    defp number("0x" <> hex), do: String.to_integer(hex, 16)
  end

  # A12: the row had no prepare-and-send, so a press before its review arrived
  # sent nothing (money-path audit, 12 Nov 2026).
  test "a press with no review on the row is prepared and sent", %{conn: conn} = context do
    put_env(:autolaunch_lab_http_client, Robinhood)
    {view, row} = row(conn, context)
    render_hook(row, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{steps: [%{step: "exit", data: data}]}})
    assert data == BuilderCode.append(exit_bid_data())
  end

  test "a settlement Robinhood could not read keeps its button, and the next press asks again",
       %{conn: conn} = context do
    put_env(:autolaunch_lab_http_client, BaseRpcStub.Timeout)
    {view, row} = row(conn, context)
    render_async(view)

    assert render(view) =~ "Robinhood could not be read just now. Try again in a moment."
    assert has_element?(view, ~s(#row [data-onchain-step="settle"]), "Refund your stock")

    put_env(:autolaunch_lab_http_client, Robinhood)
    render_hook(row, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{steps: [%{step: "exit"}]}})
  end

  # The auction takes a return from any sender and pays the bid's owner, yet
  # only the bid's own wallet could prepare it (review of A7, 12 Nov 2026).
  test "a bid of another wallet the account links is prepared for the open one, which the row names",
       %{conn: conn, wallet: holder} do
    put_env(:autolaunch_lab_http_client, Robinhood)
    unique = Elixir.System.unique_integer([:positive])

    account =
      Autolaunch.Accounts.register_verified!("did:privy:open-#{unique}", @open, [@open, holder],
        actor: %System{}
      )

    {view, row} = row(conn, account, holder, @open)
    render_hook(row, "prepare_and_send", %{"form" => %{}, "step" => "settle"})

    assert_reply(view, %{send: "exit", review: %{signer: @open, steps: [%{step: "exit"}]}})
    assert has_element?(view, "#row-paid-to-full", holder)

    # An account that does not link the bid's wallet cannot prepare it.
    stranger =
      Autolaunch.Accounts.register_verified!("did:privy:other-#{unique}", @other, [@other],
        actor: %System{}
      )

    opts = [
      actor: %Autolaunch.Actors.Human{human_account_id: stranger.id},
      context: %{session_lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(stranger.id)}
    ]

    assert {:error, %Ash.Error.Invalid.Unavailable{reason: :not_your_bid}} =
             Autolaunch.Robinhood.StockBidSettlementActions.prepare(
               %{auction: "0x3000000000000000000000000000000000000003", bid_id: "7"},
               @other,
               opts
             )
  end

  defp row(conn, context), do: row(conn, context.account, context.wallet, context.wallet)

  defp row(conn, account, owner, active) do
    session = signed_in_session(account.id)

    {:ok, view, _html} =
      conn
      |> Phoenix.ConnTest.init_test_session(session)
      |> connects_with(session)
      |> live_isolated(__MODULE__.Row, session: %{"account_id" => account.id, "owner" => owner})

    row = with_target(view, "#row")
    render_hook(row, "onchain_active_wallet", %{"address" => active})
    {view, row}
  end

  defp exit_bid_data,
    do: LabAbi.selector("exitBid(uint256)") <> BaseRpcStub.hex_word(@bid_id)

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, key, previous),
        else: Application.delete_env(:autolaunch, key)
    end)
  end
end
