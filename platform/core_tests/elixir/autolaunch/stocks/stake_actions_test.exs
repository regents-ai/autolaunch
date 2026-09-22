defmodule Autolaunch.Stocks.StakeActionsTest do
  @moduledoc """
  Protects one invariant: collecting a Base Revstake launch's trading fees is
  reviewed as exactly one step, `collect(<that launch's lp_token_id>)` on the
  deployment's `lp_locker`, bound to that locker and showing the fees the
  locker itself says the call would deposit.
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

  # Every block-pinned read the review makes, answered by selector. The subject
  # sorts after REGENT, so REGENT is currency0 and the locker's simulated
  # `collect` answers 2 REGENT then 1 LRVS.
  defp answer(data, config) do
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
      LabAbi.selector("claimable(address,address)") => [0]
    }

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
