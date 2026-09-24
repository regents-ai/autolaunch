defmodule Autolaunch.Stocks.StakeActionsTest do
  @moduledoc """
  Protects two invariants. Collecting a Base Revstake launch's trading fees is
  reviewed as exactly one step, `collect(<that launch's lp_token_id>)` on the
  deployment's `lp_locker`, bound to that locker and showing the fees the
  locker itself says the call would deposit. A payment into its revenue split
  approves exactly the reviewed amount to the launch's payment receiver, and is
  confirmed only by that receiver's one `PaymentRouted` carrying the reviewed
  reference, asset and amount; a sweep's amount is the event's own.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture, only: [bidder: 1]

  alias Autolaunch.{BaseRpcStub, Lab, LabAbi}
  alias Autolaunch.Stocks.StakeActions

  @subject "0x9999999999999999999999999999999999999999"
  @escrow "0x7777777777777777777777777777777777777777"
  @splitter "0x8888888888888888888888888888888888888888"
  @receiver "0x6666666666666666666666666666666666666666"
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @live_staking "0x5555555555555555555555555555555555555555"
  @hash "0x" <> String.duplicate("ab", 32)
  @lp_token_id 4_242
  @q96 79_228_162_514_264_337_593_543_950_336
  @extsload "0x1e2eaeaf"
  @owner_of "0x6352211e"

  setup :bidder

  test "collect on a Base Revstake launch is one collect(lp_token_id) step on the lp_locker",
       context do
    config = Lab.current!()
    lp_locker = Lab.address!(config, :lp_locker)
    auction = Autolaunch.TestSupport.project_auction(state: :graduated, symbol: "LRVS")

    BaseRpcStub.install(:autolaunch_lab_http_client, fn data, _state -> answer(data, config) end)

    BaseRpcStub.put(%{
      blocks: %{"latest" => %{"number" => "0x20", "hash" => BaseRpcStub.safe_hash()}}
    })

    request = %{kind: :collect, launch: %{chain: :base, auction: auction}}

    assert {:ok, %{kind: :collect, steps: steps, review: review, envelope: envelope}} =
             StakeActions.prepare(request, context.wallet, context.opts)

    assert [%{"step" => "collect_full_range", "to" => ^lp_locker, "data" => data}] = steps
    assert data == LabAbi.selector("collect(uint256)") <> BaseRpcStub.hex_word(@lp_token_id)
    assert review == [["Full range position", "1 LRVS · 2 REGENT"]]
    assert envelope["arguments"]["locker"] == lp_locker

    assert envelope["metadata"]["lab"]["addresses"] |> Map.keys() |> Enum.sort() ==
             ["hook", "lp_locker", "strategy"]
  end

  describe "a payment into the revenue split" do
    setup context do
      auction = Autolaunch.TestSupport.project_auction(state: :graduated, symbol: "LRVS")
      Map.put(context, :launch, %{chain: :base, auction: auction})
    end

    test "approves exactly the amount to the payment receiver, then pays it there", context do
      stub(%{LabAbi.selector("balanceOf(address)") => [10 * 10 ** 6]})
      request = %{kind: :pay, launch: context.launch, asset: "usdc", amount: "2.5"}

      assert {:ok, %{steps: [approval, pay], envelope: envelope}} =
               StakeActions.prepare(request, context.wallet, context.opts)

      assert approval["step"] == "token_approval"
      assert approval["to"] == @usdc

      assert approval["data"] ==
               LabAbi.selector("approve(address,uint256)") <>
                 BaseRpcStub.address_word(@receiver) <> BaseRpcStub.hex_word(2_500_000)

      assert pay["step"] == "pay"
      assert pay["to"] == @receiver

      assert pay["data"] ==
               LabAbi.selector("pay(address,uint256,bytes32)") <>
                 BaseRpcStub.address_word(@usdc) <>
                 BaseRpcStub.hex_word(2_500_000) <>
                 String.trim_leading(envelope["arguments"]["payment_ref"], "0x")
    end

    test "is confirmed only by the reviewed reference, asset and amount", context do
      stub(%{LabAbi.selector("balanceOf(address)") => [10 * 10 ** 6]})
      request = %{kind: :pay, launch: context.launch, asset: "usdc", amount: "2.5"}

      {:ok, %{steps: [_approval, pay], envelope: envelope}} =
        StakeActions.prepare(request, context.wallet, context.opts)

      ref = envelope["arguments"]["payment_ref"]
      other_ref = "0x" <> String.duplicate("cd", 32)

      assert {:ok, %{outcome: :confirmed, result: %{"gross_units" => "2.5"}}} =
               routed(context, envelope, :pay, pay, routed_log(ref, @usdc, 2_500_000))

      for log <- [
            routed_log(other_ref, @usdc, 2_500_000),
            routed_log(ref, Lab.address!(Lab.current!(), :regent), 2_500_000),
            routed_log(ref, @usdc, 2_500_001)
          ] do
        assert {:error, %{reason: :payment_not_routed}} =
                 routed(context, envelope, :pay, pay, log)
      end
    end

    test "a sweep routes whatever was waiting and reports the event's amount", context do
      stub(%{LabAbi.selector("balanceOf(address)") => [3 * 10 ** 6]})
      request = %{kind: :sweep, launch: context.launch, asset: "usdc"}

      assert {:ok, %{steps: [sweep], envelope: envelope}} =
               StakeActions.prepare(request, context.wallet, context.opts)

      assert sweep["data"] ==
               LabAbi.selector("sweep(address)") <> BaseRpcStub.address_word(@usdc)

      ref = envelope["arguments"]["payment_ref"]

      assert {:ok, %{outcome: :confirmed, result: %{"gross_units" => "4.25"}}} =
               routed(context, envelope, :sweep, sweep, routed_log(ref, @usdc, 4_250_000))
    end
  end

  defp stub(overrides) do
    config = Lab.current!()

    BaseRpcStub.install(:autolaunch_lab_http_client, fn data, _state ->
      answer(data, config, overrides)
    end)

    BaseRpcStub.put(%{
      blocks: %{"latest" => %{"number" => "0x20", "hash" => BaseRpcStub.safe_hash()}}
    })
  end

  # Confirms one reviewed step against a mined transaction carrying this log.
  defp routed(context, envelope, step, sent, log) do
    BaseRpcStub.put(%{
      receipts: %{@hash => BaseRpcStub.receipt(@hash, "0x10", [log])},
      transactions: %{
        @hash => %{
          "hash" => @hash,
          "from" => context.wallet,
          "to" => sent["to"],
          "input" => sent["data"],
          "value" => "0x0"
        }
      }
    })

    StakeActions.verify(envelope, step, @hash, context.opts)
  end

  defp routed_log(ref, token, gross) do
    %{
      "address" => @receiver,
      "topics" => [
        LabAbi.topic(LabAbi.payment_routed_signature()),
        ref,
        BaseRpcStub.address_topic(@receiver),
        BaseRpcStub.address_topic(token)
      ],
      "data" => "0x" <> Enum.map_join([gross, 0, gross], &BaseRpcStub.hex_word/1)
    }
  end

  # Every block-pinned read the review makes, answered by selector. The subject
  # sorts after REGENT, so REGENT is currency0 and the locker's simulated
  # `collect` answers 2 REGENT then 1 LRVS.
  defp answer(data, config, overrides \\ %{}) do
    answers = %{
      LabAbi.selector("distribution(address)") => distribution(),
      LabAbi.selector("POOL_FEE()") => [3_000],
      LabAbi.selector("POOL_TICK_SPACING()") => [60],
      LabAbi.selector("remainingSupply()") => [0],
      @extsload => [@q96],
      @owner_of => [word(Lab.address!(config, :lp_locker))],
      LabAbi.selector("totalStaked()") => [0],
      LabAbi.selector("SKIM_BPS()") => [200],
      LabAbi.selector("usdc()") => [word(@usdc)],
      LabAbi.selector("collect(uint256)") => [2 * 10 ** 18, 10 ** 18],
      LabAbi.selector("balanceOf(address)") => [0],
      LabAbi.selector("allowance(address,address)") => [0],
      LabAbi.selector("stakedOf(address)") => [0],
      LabAbi.selector("claimable(address,address)") => [0],
      LabAbi.selector("liveStaking()") => [word(@live_staking)],
      LabAbi.selector("paused()") => [0]
    }

    answers = Map.merge(answers, overrides)

    "0x" <> Enum.map_join(Map.fetch!(answers, String.slice(data, 0, 10)), &BaseRpcStub.hex_word/1)
  end

  # The strategy's eighteen-word `distribution` record of a migrated launch.
  defp distribution do
    [
      0,
      0,
      0,
      0,
      10,
      0,
      0,
      5 * 10 ** 18,
      7 * 10 ** 18,
      @q96,
      0,
      word(@subject),
      word(@escrow),
      0,
      word(@splitter),
      word(@receiver),
      1,
      @lp_token_id
    ]
  end

  defp word("0x" <> hex), do: String.to_integer(hex, 16)
end
