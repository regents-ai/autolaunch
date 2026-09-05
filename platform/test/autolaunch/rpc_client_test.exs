defmodule Autolaunch.RpcClientTest do
  use ExUnit.Case, async: false

  alias Autolaunch.BaseRpcStub
  alias Autolaunch.Chain.{Abi, AuctionAbi, Permit2Abi}
  alias Autolaunch.RpcClient

  @wallet "0x1111111111111111111111111111111111111111"
  @auction "0x2222222222222222222222222222222222222222"
  @regent String.downcase(Abi.regent_address())
  @hash "0x" <> String.duplicate("ab", 32)
  @amount 12_500_000_000_000_000_000
  @price_q96 3 * 79_228_162_514_264_337_593_543_950_336
  @expiration 1_790_000_000

  setup do
    BaseRpcStub.install(:autolaunch_bid_http_client, fn data, _state ->
      raise "unscripted block-pinned read #{data}"
    end)

    :ok
  end

  test "PRODUCTION_STAYS_CLOSED: no snapshot is taken and no provider is contacted" do
    assert RpcClient.snapshot(%{
             auction: @auction,
             signer: @wallet,
             max_price_q96: @price_q96
           }) == {:error, :bid_preparation_unavailable}

    refute_received {:rpc, _method, _params}
  end

  test "CANONICAL_CONFIRMATION: only the auction's own exact event confirms a bid and names it" do
    calls(%{})
    mine(@hash, envelope()["data"], [bid_log(7, @wallet, @price_q96, @amount)])

    assert {:ok, %{outcome: :confirmed, onchain_bid_id: "7"}} =
             RpcClient.verify(envelope(), :bid, @hash)
  end

  test "CANONICAL_CONFIRMATION: contradictory, duplicated and foreign events never confirm" do
    calls(%{})
    data = envelope()["data"]

    for logs <- [
          [],
          [bid_log(7, @wallet, @price_q96, @amount + 1)],
          [bid_log(7, @wallet, @price_q96 + 1, @amount)],
          [bid_log(7, "0x3333333333333333333333333333333333333333", @price_q96, @amount)],
          [%{bid_log(7, @wallet, @price_q96, @amount) | "address" => @regent}],
          [bid_log(7, @wallet, @price_q96, @amount), bid_log(8, @wallet, @price_q96, @amount)]
        ] do
      mine(@hash, data, logs)
      assert {:ok, %{outcome: :unverified}} = RpcClient.verify(envelope(), :bid, @hash)
    end
  end

  test "A_REVERT_IS_NEVER_SUCCESS: a canonical revert reports exactly that" do
    calls(%{})
    mine(@hash, envelope()["data"], [], "0x0")

    assert {:ok, %{outcome: :reverted}} = RpcClient.verify(envelope(), :bid, @hash)
  end

  test "UNSETTLED_STAYS_PENDING: an unobserved hash and one above the safe head both wait" do
    calls(%{})
    assert {:ok, %{outcome: :pending}} = RpcClient.verify(envelope(), :bid, @hash)

    mine(@hash, envelope()["data"], [bid_log(7, @wallet, @price_q96, @amount)], "0x1", "0x99")
    assert {:ok, %{outcome: :pending}} = RpcClient.verify(envelope(), :bid, @hash)
  end

  test "APPROVALS_NEED_THEIR_ALLOWANCE: only the exact reviewed allowance advances the sequence" do
    approval = Abi.encode_erc20("approve", [Permit2Abi.address(), @amount])
    mine(@hash, approval, [approval_log(@regent, @wallet, Permit2Abi.address(), @amount)])
    allowance = Abi.encode_erc20("allowance", [@wallet, Permit2Abi.address()])

    calls(%{allowance => @amount})

    assert {:ok, %{outcome: :confirmed}} =
             RpcClient.verify(envelope(), :token_approval, @hash)

    # This transaction was prepared to leave one exact allowance behind, so any
    # other standing amount is a state the review cannot vouch for.
    for other <- [@amount - 1, @amount + 1] do
      calls(%{allowance => other})

      assert {:ok, %{outcome: :unverified}} =
               RpcClient.verify(envelope(), :token_approval, @hash)
    end
  end

  test "APPROVALS_NEED_THEIR_ALLOWANCE: a Permit2 grant is read back for its exact amount and expiry" do
    data = Permit2Abi.encode_approve(@regent, @auction, @amount, @expiration)
    mine(@hash, data, [])
    allowance = Permit2Abi.encode_allowance(@wallet, @regent, @auction)

    calls(%{allowance => [@amount, @expiration, 0]})

    assert {:ok, %{outcome: :confirmed}} =
             RpcClient.verify(envelope(), :permit2_approval, @hash)

    for other <- [
          [@amount - 1, @expiration, 0],
          [@amount + 1, @expiration, 0],
          [@amount, @expiration - 1, 0],
          [@amount, @expiration + 1, 0]
        ] do
      calls(%{allowance => other})

      assert {:ok, %{outcome: :unverified}} =
               RpcClient.verify(envelope(), :permit2_approval, @hash)
    end
  end

  test "APPROVALS_NEED_THEIR_ALLOWANCE: words wider than the declared interface settle nothing" do
    data = Permit2Abi.encode_approve(@regent, @auction, @amount, @expiration)
    mine(@hash, data, [])
    allowance = Permit2Abi.encode_allowance(@wallet, @regent, @auction)

    for malformed <- [
          [Integer.pow(2, 160), @expiration, 0],
          [@amount, Integer.pow(2, 48), 0]
        ] do
      calls(%{allowance => malformed})

      assert {:error, :invalid_chain_response} =
               RpcClient.verify(envelope(), :permit2_approval, @hash)
    end
  end

  test "THE_BOUND_IDENTITY_DECIDES: a transaction from another signer or target is refused" do
    calls(%{})
    mine(@hash, envelope()["data"], [bid_log(7, @wallet, @price_q96, @amount)])

    BaseRpcStub.put(%{
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "from" => @regent,
          "to" => @auction,
          "input" => envelope()["data"],
          "value" => "0x0"
        }
      }
    })

    assert {:error, :transaction_mismatch} = RpcClient.verify(envelope(), :bid, @hash)
  end

  test "tests configure only the injectable client and an invalid reserved endpoint" do
    assert Application.fetch_env!(:autolaunch, :base_read_rpc_url) =~ "provider.invalid"
    assert Application.fetch_env!(:autolaunch, :autolaunch_bid_http_client) == BaseRpcStub
  end

  defp envelope do
    %{
      "to" => @auction,
      "expected_signer" => @wallet,
      "data" => AuctionAbi.encode_submit_bid(@price_q96, @amount, @wallet, div(@price_q96, 2)),
      "arguments" => %{
        "amount_atomic" => Integer.to_string(@amount),
        "max_price_q96" => Integer.to_string(@price_q96),
        "currency" => @regent,
        "steps" => [
          %{
            "step" => "token_approval",
            "to" => @regent,
            "data" => Abi.encode_erc20("approve", [Permit2Abi.address(), @amount]),
            "amount" => Integer.to_string(@amount)
          },
          %{
            "step" => "permit2_approval",
            "to" => Permit2Abi.address(),
            "data" => Permit2Abi.encode_approve(@regent, @auction, @amount, @expiration),
            "amount" => Integer.to_string(@amount),
            "expiration" => Integer.to_string(@expiration)
          },
          %{
            "step" => "bid",
            "to" => @auction,
            "data" =>
              AuctionAbi.encode_submit_bid(@price_q96, @amount, @wallet, div(@price_q96, 2))
          }
        ]
      }
    }
  end

  defp mine(hash, data, logs, status \\ "0x1", block \\ "0x10") do
    to = if data == envelope()["data"], do: @auction, else: target(data)

    BaseRpcStub.put(%{
      receipts: %{hash => BaseRpcStub.receipt(hash, block, logs, status)},
      transactions: %{
        hash => %{
          "hash" => hash,
          "from" => @wallet,
          "to" => to,
          "input" => data,
          "value" => "0x0"
        }
      }
    })
  end

  defp target(data) do
    Enum.find_value(envelope()["arguments"]["steps"], fn step ->
      if step["data"] == data, do: step["to"]
    end)
  end

  defp calls(answers) do
    BaseRpcStub.put(%{
      calls: fn data, _state ->
        case Map.fetch!(answers, data) do
          words when is_list(words) -> "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
          value -> BaseRpcStub.uint(value)
        end
      end
    })
  end

  defp bid_log(id, owner, price_q96, amount) do
    %{
      "address" => @auction,
      "topics" => [
        AuctionAbi.bid_submitted_topic(),
        "0x" <> BaseRpcStub.hex_word(id),
        BaseRpcStub.address_topic(owner)
      ],
      "data" => "0x" <> BaseRpcStub.hex_word(price_q96) <> BaseRpcStub.hex_word(amount)
    }
  end

  defp approval_log(token, owner, spender, amount) do
    %{
      "address" => token,
      "topics" => [
        Abi.event_topic(:approval),
        BaseRpcStub.address_topic(owner),
        BaseRpcStub.address_topic(spender)
      ],
      "data" => "0x" <> BaseRpcStub.hex_word(amount)
    }
  end
end
