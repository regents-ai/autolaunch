defmodule Autolaunch.BidSettlementActionsTest do
  @moduledoc """
  Protects one invariant: the settlement review carries exactly the steps the
  auction itself would accept, with the calldata the contract expects, and a
  position this account does not own is never reviewed.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.Actors.System
  alias Autolaunch.{BidSettlementActions, LabAbi, TestAutolaunchBidSettlementChainClient}
  alias RegentChain.BuilderCode

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

    assert {:ok, %{steps: [%{step: "exit", data: data, to: to}], facts: facts}} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert data == BuilderCode.append(exit_bid_data())
    assert to == Autolaunch.BidFixture.auction_address()
    assert facts.currency_refunded == "5"
    assert facts.graduated == false
  end

  test "a graduated auction with a bid above the final price exits, then claims", context do
    position = position!(context, context.wallet)

    install(
      graduated?: true,
      exit: exit_bid(refund: 0, filled: 1_200_000 * 10 ** 18),
      claim: %{data: claim_data(), tokens_claimed: 1_200_000 * 10 ** 18}
    )

    assert {:ok,
            %{
              steps: [%{step: "exit", data: exit_data}, %{step: "claim", data: claim_data}],
              facts: facts
            }} = BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert exit_data == BuilderCode.append(exit_bid_data())
    assert claim_data == BuilderCode.append(claim_data())
    assert facts.tokens_claimed == "1200000"
  end

  test "an exited bid with fill after the claim block has only the claim step", context do
    position = position!(context, context.wallet)

    install(
      graduated?: true,
      exit: {:refused, :already_exited},
      claim: %{data: claim_data(), tokens_claimed: 10 ** 18}
    )

    assert {:ok, %{steps: [%{step: "claim", data: data}]}} =
             BidSettlementActions.prepare(position.id, context.wallet, context.opts)

    assert data == BuilderCode.append(claim_data())
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

  # The auction takes a return from any sender and pays the bid's owner, yet
  # only the bid's own wallet could prepare it (review of A7, 12 Nov 2026).
  test "a bid of another wallet the account links is prepared for the open one and read for its own",
       context do
    unique = Elixir.System.unique_integer([:positive])
    holder = Autolaunch.BidFixture.wallet()

    account =
      Autolaunch.Accounts.register_verified!("did:privy:open-#{unique}", @other, [@other, holder],
        actor: %System{}
      )

    opts = [
      actor: %Autolaunch.Actors.Human{human_account_id: account.id},
      context: %{session_lease: AutolaunchWeb.SessionAuthorityHelpers.current_lease(account.id)}
    ]

    position = position!(context, holder)

    install(
      graduated?: false,
      exit: exit_bid(refund: 5 * 10 ** 18, filled: 0),
      claim: {:refused, :nothing_to_claim}
    )

    assert {:ok, %{steps: [%{step: "exit", data: data}], context: settled}} =
             BidSettlementActions.prepare(position.id, @other, opts)

    assert data == BuilderCode.append(exit_bid_data())

    # Sent from the open wallet, the auction's receipt names the bid's own.
    assert %{"currency_refunded" => "5000000000000000000"} =
             BidSettlementActions.result(settled, "exit", [bid_exited(holder)])

    assert BidSettlementActions.result(settled, "exit", [bid_exited(@other)]) == nil
  end

  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason

  defp bid_exited(owner),
    do: %{
      "address" => Autolaunch.BidFixture.auction_address(),
      "blockHash" => "0x" <> String.duplicate("ab", 32),
      "topics" => [
        LabAbi.topic("BidExited(uint256,address,uint256,uint256)"),
        "0x" <> word(@bid_id),
        "0x" <> String.pad_leading(String.trim_leading(owner, "0x"), 64, "0")
      ],
      "data" => "0x" <> word(0) <> word(5 * 10 ** 18)
    }

  defp position!(%{auction: auction}, owner) do
    unique = Elixir.System.unique_integer([:positive])

    Autolaunch.Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: "lab:settle:#{unique}",
        auction_id: auction.id,
        owner_address: owner,
        amount: "12",
        max_price: "0.00003",
        current_clearing_price: "0.00002",
        status: :returnable,
        auction_address: Autolaunch.BidFixture.auction_address(),
        onchain_bid_id: Integer.to_string(@bid_id)
      },
      actor: %System{}
    )
    |> Ash.create!()
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
