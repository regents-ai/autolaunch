defmodule Autolaunch.RevenuePaymentsTest do
  @moduledoc """
  Protects one invariant: the payment history records each `PaymentRouted`
  the launch's payment receiver emitted with its exact asset, amounts,
  reference, block and time, names the payer from the transfer into the
  receiver in the same transaction, and names none for a sweep.
  """

  use Autolaunch.DataCase, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, RevenuePayments}

  @subject "0x9999999999999999999999999999999999999999"
  @escrow "0x7777777777777777777777777777777777777777"
  @splitter "0x8888888888888888888888888888888888888888"
  @receiver "0x6666666666666666666666666666666666666666"
  @payer "0x4444444444444444444444444444444444444444"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @paid "0x" <> String.duplicate("a1", 32)
  @swept "0x" <> String.duplicate("a2", 32)
  @ref "0x" <> String.duplicate("0f", 32)
  @zero_ref "0x" <> String.duplicate("00", 32)
  @hash_16 "0x" <> String.duplicate("16", 32)
  @hash_32 "0x" <> String.duplicate("32", 32)

  test "decodes each routed payment, with the payer when the payment brought its own transfer" do
    auction = Autolaunch.TestSupport.project_auction(state: :graduated, symbol: "LRVS")
    stub()

    assert :ok = RevenuePayments.refresh(auction)

    assert {:ok, [swept, paid]} = Autolaunch.recent_revenue_payments(auction.id)

    assert %{
             token: @usdc,
             token_symbol: "USDC",
             payer: @payer,
             payment_ref: @ref,
             transaction_hash: @paid,
             log_index: 3,
             block_number: 16,
             block_hash: @hash_16,
             receiver: @receiver
           } = paid

    assert Decimal.equal?(paid.gross, Decimal.new("2.5"))
    assert Decimal.equal?(paid.net, Decimal.new("2.5"))
    assert DateTime.compare(paid.occurred_at, DateTime.from_unix!(1_700_000_016)) == :eq

    assert %{token: @subject, token_symbol: "LRVS", payer: nil, payment_ref: @zero_ref} = swept
    assert Decimal.equal?(swept.gross, Decimal.new("1234.000000000000000001"))
    assert swept.block_number == 32
  end

  defp stub do
    BaseRpcStub.install(:autolaunch_lab_http_client, fn data, _state -> answer(data) end)

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => header(32, @hash_32),
        "0x10" => header(16, @hash_16),
        "0x20" => header(32, @hash_32)
      },
      logs: fn
        %{address: @receiver} ->
          [
            routed(@paid, 16, @hash_16, 3, @ref, @usdc, 2_500_000),
            routed(@swept, 32, @hash_32, 0, @zero_ref, @subject, 1_234 * 10 ** 18 + 1)
          ]

        %{address: assets} when is_list(assets) ->
          [transfer(@paid, 16, @hash_16, 2, @usdc, @payer, 2_500_000)]
      end
    })
  end

  defp header(number, hash),
    do: %{
      "number" => BaseRpcStub.uint(number),
      "hash" => hash,
      "timestamp" => BaseRpcStub.uint(1_700_000_000 + number)
    }

  defp routed(transaction, block, block_hash, index, ref, token, gross),
    do:
      log(@receiver, transaction, block, block_hash, index, [
        LabAbi.topic(LabAbi.payment_routed_signature()),
        ref,
        BaseRpcStub.address_topic(@receiver),
        BaseRpcStub.address_topic(token)
      ])
      |> Map.put("data", "0x" <> Enum.map_join([gross, 0, gross], &BaseRpcStub.hex_word/1))

  defp transfer(transaction, block, block_hash, index, token, from, amount),
    do:
      log(token, transaction, block, block_hash, index, [
        LabAbi.topic("Transfer(address,address,uint256)"),
        BaseRpcStub.address_topic(from),
        BaseRpcStub.address_topic(@receiver)
      ])
      |> Map.put("data", BaseRpcStub.uint(amount))

  defp log(address, transaction, block, block_hash, index, topics),
    do: %{
      "address" => address,
      "topics" => topics,
      "transactionHash" => transaction,
      "blockNumber" => BaseRpcStub.uint(block),
      "blockHash" => block_hash,
      "logIndex" => BaseRpcStub.uint(index),
      "removed" => false
    }

  # The migrated launch's `distribution` record, migrated in block 10, and the
  # splitter's dollar asset.
  defp answer(data) do
    answers = %{
      LabAbi.selector("distribution(address)") => distribution(),
      LabAbi.selector("usdc()") => [word(@usdc)]
    }

    "0x" <> Enum.map_join(Map.fetch!(answers, String.slice(data, 0, 10)), &BaseRpcStub.hex_word/1)
  end

  defp distribution,
    do:
      [0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, word(@subject), word(@escrow), 0, word(@splitter)] ++
        [word(@receiver), 1, 1]

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
