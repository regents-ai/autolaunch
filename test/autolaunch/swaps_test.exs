defmodule Autolaunch.SwapsTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.{Accounts, Swaps, Tokens}

  @wallet "0x1111111111111111111111111111111111111111"
  @approval_spender "0x2222222222222222222222222222222222222222"
  @swap_target "0x3333333333333333333333333333333333333333"
  @other_target "0x4444444444444444444444444444444444444444"
  @token "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    previous = Application.get_env(:autolaunch, :swaps)

    Application.put_env(:autolaunch, :swaps,
      enabled: true,
      uniswap_api_base_url: "https://uniswap.test/v1",
      uniswap_api_key: "test-key",
      allowed_transaction_targets: %{8_453 => [@swap_target], 84_532 => [@swap_target]},
      allowed_approval_spenders: %{8_453 => [@approval_spender], 84_532 => [@approval_spender]},
      max_price_impact_percent: "5",
      client: __MODULE__.Client
    )

    on_exit(fn -> Application.put_env(:autolaunch, :swaps, previous) end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("privy-swapper", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet]
      })

    insert_revsplit_token()

    {:ok, human: human}
  end

  test "is unavailable when allowlists are missing" do
    Application.put_env(:autolaunch, :swaps,
      enabled: true,
      uniswap_api_base_url: "https://uniswap.test/v1",
      uniswap_api_key: "test-key",
      allowed_transaction_targets: %{},
      allowed_approval_spenders: %{},
      max_price_impact_percent: "5",
      client: __MODULE__.Client
    )

    refute Swaps.available?()
    refute Swaps.available?(8_453)
  end

  test "quotes exact Base USDC buys through v4 only", %{human: human} do
    assert {:ok, %{quote: quote}} =
             Swaps.quote(
               %{
                 "side" => "buy",
                 "chain_id" => 8_453,
                 "token_address" => @token,
                 "amount" => "12.50",
                 "slippage_bps" => 100,
                 "swapper" => @wallet
               },
               human
             )

    assert quote.side == "buy"
    assert quote.chain_id == 8_453
    assert quote.amount_in_raw == "12500000"
    assert quote.amount_out_raw == "25000000000000000000"
    assert quote.minimum_amount_out_raw == "24500000000000000000"
    assert quote.route_label == "Uniswap v4"
    assert quote.approval.owner_product == "autolaunch"
    assert quote.approval.resource == "swap"
    assert quote.approval.action == "approve"
    assert quote.approval.chain_id == 8_453
    assert quote.approval.to == "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
    assert quote.approval.value == "0x0"
    assert quote.approval.expected_signer == @wallet
    assert quote.approval.idempotency_key =~ "swap-approval:8453:buy"
    assert is_binary(quote.approval.risk_copy)
  end

  test "prepares a wallet action for the Uniswap swap transaction", %{human: human} do
    assert {:ok, %{swap: %{wallet_action: action}}} =
             Swaps.prepare(
               %{
                 "side" => "sell",
                 "chain_id" => 8_453,
                 "token_address" => @token,
                 "amount" => "4",
                 "slippage_bps" => 100,
                 "swapper" => @wallet
               },
               human
             )

    assert String.starts_with?(action.action_id, "uniswap_v4_swap:")
    assert action.action == "sell"
    assert action.chain_id == 8_453
    assert action.to == @swap_target
    assert action.value == "0x0"
    assert action.data == "0xabcdef12"
    assert action.expected_signer == @wallet
  end

  test "rejects swap transactions to unapproved targets", %{human: human} do
    Process.put(:swap_tx, %{
      "to" => @other_target,
      "value" => "0x0",
      "data" => "0xabcdef12"
    })

    assert {:error, :invalid_swap_transaction} =
             Swaps.prepare(valid_attrs("sell", "4"), human)
  end

  test "rejects swap transactions for a different chain", %{human: human} do
    Process.put(:swap_tx, %{
      "to" => @swap_target,
      "value" => "0x0",
      "data" => "0xabcdef12",
      "chainId" => 84_532
    })

    assert {:error, :invalid_swap_transaction} =
             Swaps.prepare(valid_attrs("sell", "4"), human)
  end

  test "rejects malformed swap calldata", %{human: human} do
    Process.put(:swap_tx, %{
      "to" => @swap_target,
      "value" => "0x0",
      "data" => "0xabc"
    })

    assert {:error, :invalid_swap_transaction} =
             Swaps.prepare(valid_attrs("sell", "4"), human)
  end

  test "rejects swap transactions that include native ETH", %{human: human} do
    Process.put(:swap_tx, %{
      "to" => @swap_target,
      "value" => "0x1",
      "data" => "0xabcdef12",
      "chainId" => 8_453
    })

    assert {:error, :invalid_swap_transaction} =
             Swaps.prepare(valid_attrs("sell", "4"), human)
  end

  test "rejects high price impact quotes", %{human: human} do
    Process.put(:price_impact, "7.25")

    assert {:error, :price_impact_too_high} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "rejects non-finite price impact quotes", %{human: human} do
    Process.put(:price_impact, "NaN")

    assert {:error, :price_impact_unavailable} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "rejects non-contract amount strings", %{human: human} do
    for amount <- ["NaN", "Infinity", "1e3", ".5", "1."] do
      assert {:error, :invalid_amount} =
               Swaps.quote(valid_attrs("buy", amount), human)
    end
  end

  test "request changes produce distinct idempotency keys", %{human: human} do
    assert {:ok, %{swap: %{wallet_action: first}}} =
             Swaps.prepare(valid_attrs("sell", "4", 100), human)

    assert {:ok, %{swap: %{wallet_action: second}}} =
             Swaps.prepare(valid_attrs("sell", "4", 200), human)

    refute first.idempotency_key == second.idempotency_key
    refute first.action_id == second.action_id
  end

  test "rejects approval transactions for unapproved spenders", %{human: human} do
    Process.put(:approval_spender, @other_target)

    assert {:error, :invalid_approval_transaction} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "rejects approval transactions that include native ETH", %{human: human} do
    Process.put(:approval_value, "0x1")

    assert {:error, :invalid_approval_transaction} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "accepts approval transactions without a native value field", %{human: human} do
    Process.put(:approval_omit_value, true)

    assert {:ok, %{quote: quote}} = Swaps.quote(valid_attrs("buy", "12.50"), human)
    assert quote.approval.value == "0x0"
  end

  test "rejects approval transactions for the wrong token amount", %{human: human} do
    Process.put(:approval_amount, "0")

    assert {:error, :invalid_approval_transaction} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "rejects non-v4 routes", %{human: human} do
    assert {:error, :unsupported_route} =
             Swaps.quote(
               %{
                 "side" => "buy",
                 "chain_id" => 8_453,
                 "token_address" => @token,
                 "amount" => "1",
                 "slippage_bps" => 100,
                 "swapper" => @wallet,
                 "test_route" => "v3"
               },
               human
             )
  end

  test "rejects empty routes", %{human: human} do
    Process.put(:quote_route, [])

    assert {:error, :unsupported_route} =
             Swaps.quote(valid_attrs("buy", "12.50"), human)
  end

  test "requires the swapper to be a linked Privy wallet", %{human: human} do
    assert {:error, :wallet_mismatch} =
             Swaps.quote(
               %{
                 "side" => "buy",
                 "chain_id" => 8_453,
                 "token_address" => @token,
                 "amount" => "1",
                 "slippage_bps" => 100,
                 "swapper" => "0x9999999999999999999999999999999999999999"
               },
               human
             )
  end

  test "rejects non-canonical swap request integer fields", %{human: human} do
    assert {:error, :unsupported_chain} =
             Swaps.quote(%{valid_attrs("buy", "12.50") | "chain_id" => "8453"}, human)

    assert {:error, :invalid_slippage} =
             Swaps.quote(%{valid_attrs("buy", "12.50") | "slippage_bps" => "100"}, human)
  end

  defmodule Client do
    @approval_spender "0x2222222222222222222222222222222222222222"
    @swap_target "0x3333333333333333333333333333333333333333"

    def check_approval(body, _opts) do
      spender = Process.get(:approval_spender, @approval_spender)
      value = Process.get(:approval_value, "0x0")
      amount = Process.get(:approval_amount, Map.fetch!(body, :amount))

      {:ok,
       %{
         "approval" =>
           %{
             "to" => Map.fetch!(body, :token),
             "data" => approval_data(spender, amount)
           }
           |> maybe_put_approval_value(value)
       }}
    end

    def quote(%{amount: "1000000"}, _opts), do: {:ok, quote_response([[%{"type" => "v3-pool"}]])}

    def quote(_body, _opts),
      do: {:ok, quote_response(Process.get(:quote_route, [[%{"type" => "v4-pool"}]]))}

    def swap(_body, _opts) do
      tx =
        Process.get(:swap_tx, %{
          "to" => @swap_target,
          "value" => "0x0",
          "data" => "0xabcdef12",
          "chainId" => 8_453
        })

      {:ok,
       %{
         "swap" => %{
           "transaction" => tx
         }
       }}
    end

    defp approval_data(spender, amount) do
      "0x095ea7b3" <>
        String.duplicate("0", 24) <>
        String.trim_leading(spender, "0x") <>
        (amount
         |> String.to_integer()
         |> Integer.to_string(16)
         |> String.pad_leading(64, "0"))
    end

    defp maybe_put_approval_value(approval, value) do
      if Process.get(:approval_omit_value),
        do: approval,
        else: Map.put(approval, "value", value)
    end

    defp quote_response(route) do
      %{
        "routing" => "CLASSIC",
        "quote" => %{
          "output" => %{"amount" => "25000000000000000000"},
          "aggregatedOutputs" => [%{"minAmount" => "24500000000000000000"}],
          "route" => route,
          "routeString" => "Uniswap v4",
          "priceImpact" => Process.get(:price_impact, "0.1"),
          "gasFee" => "100000"
        }
      }
    end
  end

  defp valid_attrs(side, amount, slippage_bps \\ 100) do
    %{
      "side" => side,
      "chain_id" => 8_453,
      "token_address" => @token,
      "amount" => amount,
      "slippage_bps" => slippage_bps,
      "swapper" => @wallet
    }
  end

  defp insert_revsplit_token do
    now = DateTime.utc_now()

    {:ok, token} =
      Tokens.upsert_revsplit_token(%{
        chain_id: 8_453,
        token_address: @token,
        source_auction_id: "auc_swap",
        source_job_id: "job_swap",
        auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        agent_id: "8453:1",
        agent_name: "Swap Agent",
        token_symbol: "SWAP",
        subject_id: "0x" <> String.duplicate("1", 64),
        splitter_address: "0xcccccccccccccccccccccccccccccccccccccccc",
        pool_id: "0x" <> String.duplicate("2", 64),
        graduated_at: now,
        graduation_block: 200,
        revsplit_status: "active",
        last_synced_at: now
      })

    token
  end
end
