defmodule Autolaunch.BidSettlementActionsTest do
  @moduledoc """
  Protects one invariant: the settlement envelope carries exactly the steps the
  auction itself would accept, with the calldata the contract expects, and a
  position this account does not own is never reviewed.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.Actors.System
  alias Autolaunch.{BidSettlementActions, LabAbi, TestAutolaunchBidSettlementChainClient}

  @other "0x2222222222222222222222222222222222222222"
  @bid_id 7
  @q96 79_228_162_514_264_337_593_543_950_336

  setup :bidder

  test "a failed auction settles with one exitBid step and nothing to claim", context do
    position = position!(context, context.wallet)

    install(
      graduated?: false,
      exit: exit_bid(refund: 5 * 10 ** 18, filled: 0),
      claim: {:refused, :nothing_to_claim}
    )

    assert {:ok, %{operation: operation}} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert [%{"step" => "exit", "data" => data, "to" => to}] =
             BidSettlementActions.steps(operation)

    assert data == exit_bid_data()
    assert to == Autolaunch.BidFixture.auction_address()
    assert operation.step == :exit
    assert operation.envelope["arguments"]["currency_refunded"] == "5"
    assert operation.envelope["arguments"]["graduated"] == false
  end

  test "a graduated auction with a bid above the final price exits, then claims", context do
    position = position!(context, context.wallet)

    install(
      graduated?: true,
      exit: exit_bid(refund: 0, filled: 1_200_000 * 10 ** 18),
      claim: %{data: claim_data(), tokens_claimed: 1_200_000 * 10 ** 18}
    )

    assert {:ok, %{operation: operation}} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert ["exit", "claim"] = Enum.map(BidSettlementActions.steps(operation), & &1["step"])

    assert [%{"data" => exit_data}, %{"data" => claim_data}] =
             BidSettlementActions.steps(operation)

    assert exit_data == exit_bid_data()
    assert claim_data == claim_data()
    assert operation.envelope["arguments"]["tokens_claimed"] == "1200000"
  end

  test "an exited bid with fill after the claim block has only the claim step", context do
    position = position!(context, context.wallet)

    install(
      graduated?: true,
      exit: {:refused, :already_exited},
      claim: %{data: claim_data(), tokens_claimed: 10 ** 18}
    )

    assert {:ok, %{operation: operation}} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert [%{"step" => "claim", "data" => data}] = BidSettlementActions.steps(operation)
    assert data == claim_data()
    assert operation.step == :claim
  end

  test "the auction's own refusals are the reason nothing is reviewed", context do
    position = position!(context, context.wallet)

    install(
      graduated?: false,
      exit: {:refused, :auction_not_ended},
      claim: {:refused, :claim_not_open}
    )

    assert {:error, error} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert refusal(error) == :auction_not_ended

    install(
      graduated?: true,
      exit: {:refused, :already_exited},
      claim: {:refused, :claim_not_open}
    )

    assert {:error, error} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert refusal(error) == :claim_not_open
  end

  test "another account's position is refused before the auction is read", context do
    position = position!(context, @other)

    install(
      graduated?: false,
      exit: exit_bid(refund: 1, filled: 0),
      claim: {:refused, :nothing_to_claim}
    )

    assert {:error, error} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert refusal(error) == :not_your_bid
  end

  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason

  defp position!(%{auction: auction}, owner) do
    unique = Elixir.System.unique_integer([:positive])

    {:ok, bid} =
      Autolaunch.import_bid_position(
        "lab:settle:#{unique}",
        auction.id,
        owner,
        "12",
        "0.00003",
        "0.00002",
        nil,
        "returnable",
        nil,
        nil,
        actor: %System{}
      )

    {:ok, bid} =
      Autolaunch.set_bid_chain_identity(
        bid,
        Autolaunch.BidFixture.auction_address(),
        Integer.to_string(@bid_id),
        actor: %System{}
      )

    bid
  end

  defp install(overrides) do
    TestAutolaunchBidSettlementChainClient.install(
      Map.merge(
        %{
          end_block: 90,
          claim_block: 95,
          currency: Autolaunch.BidFixture.regent(),
          final_clearing_price_q96: 2 * @q96,
          bid: %{
            start_block: 10,
            exited_block: 0,
            max_price_q96: 3 * @q96,
            owner: Autolaunch.BidFixture.wallet(),
            amount: 12 * 10 ** 18,
            tokens_filled: 0
          }
        },
        Map.new(overrides)
      )
    )
  end

  defp exit_bid(refund: refund, filled: filled),
    do: %{
      signature: "exitBid(uint256)",
      data: exit_bid_data(),
      hints: nil,
      tokens_filled: filled,
      currency_refunded: refund
    }

  defp exit_bid_data, do: LabAbi.selector("exitBid(uint256)") <> word(@bid_id)
  defp claim_data, do: LabAbi.selector("claimTokens(uint256)") <> word(@bid_id)

  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
end
