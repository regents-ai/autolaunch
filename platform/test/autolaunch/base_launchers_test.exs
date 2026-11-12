defmodule Autolaunch.BaseLaunchersTest do
  @moduledoc """
  New Base launches go to the third Revstake factory and Memestock launchpad,
  on the third's schedule, and a launch made on the second is still read and
  finished through the second's own contracts.
  """

  use ExUnit.Case, async: false

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.{Lab, LaunchActions, Pool}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions

  @base 8453

  # The test descriptions' version 3 at the top level and version 2 in their
  # `v2` sections (`test/fixtures/base-deployment.json` and
  # `test/fixtures/base-stocks-deployment.json`).
  @revstake_v3 %{
    "factory" => "0x3000000000000000000000000000000000000001",
    "strategy" => "0x3000000000000000000000000000000000000004"
  }
  @revstake_v2 %{
    "factory" => "0xcc0df8493b348bfd7c58730a2c5e97b3a73acb00",
    "hook" => "0x2e3f35f8121629e57d2cd1b382e36048e1bae044",
    "lp_locker" => "0x7f2d8a0d1b6e3c4f5a9b8c7d6e5f4a3b2c1d0e9f",
    "strategy" => "0xcf305172c24cf8b1bf58ac057c5c920987784d92"
  }
  @stocks_v3_launchpad "0x3000000000000000000000000000000000000011"
  @stocks_v2 %{
    launchpad: "0x0f8955a7f09ec713bb71c30e07b512ecee69a044",
    hook: "0x3e08453d009064ef0d1c6cb93dbc304d09f560cc",
    locker: "0xe2bc821040a50f7ca54548838b2f699a674b9160",
    bid_adapter: "0x55565be42bacfab336ef1aefbd254b9cbb738688"
  }

  test "new launches go to the third launchers, on the third's schedule" do
    revstake = Lab.current!()
    stocks = StocksLab.current!()

    assert %{version: :v3} = revstake
    assert %{version: :v3} = stocks
    assert Lab.address!(revstake, :factory) == @revstake_v3["factory"]
    assert StocksLab.address!(stocks, :launchpad) == @stocks_v3_launchpad

    # The finisher and the discoveries drive the third launchers only.
    base = Enum.filter(Launchpads.configured(), &(&1.chain_id == @base))

    assert Enum.map(base, &{&1.launchpad, &1.contract}) == [
             {:base_revstake, @revstake_v3["factory"]},
             {:base_memestock, @stocks_v3_launchpad}
           ]

    assert [%{strategy: strategy}, %{shape: %{version: :v3}}] = base
    assert strategy == @revstake_v3["strategy"]

    assert StocksLaunchActions.schedule(:base) == StocksLaunchActions.schedule(:base, :v3)
    assert LaunchActions.schedule() == LaunchActions.schedule(:v3)
  end

  test "a launch on the second launchers is read and finished through the second's contracts" do
    revstake = Lab.current!()
    assert {:ok, ^revstake} = Lab.contracts(revstake, :v3)
    assert {:ok, %{version: :v2} = earlier} = Lab.contracts(revstake, :v2)

    for {key, address} <- @revstake_v2 do
      assert Lab.address!(earlier, key) == address
      assert Lab.abi!(earlier, key) == revstake.v2.abis[key]
    end

    # What both versions share is the description's own.
    assert Lab.address!(earlier, :regent) == Lab.address!(revstake, :regent)

    stocks = StocksLab.current!()
    assert {:ok, %{version: :v2} = earlier_pad} = StocksLab.contracts(stocks, :v2)
    assert Map.take(earlier_pad, Map.keys(@stocks_v2)) == @stocks_v2

    assert :vesting_start_block in earlier_pad.record_fields
    assert {:ok, %{version: :v3, record_fields: fields}} = StocksLab.contracts(stocks, :v3)
    assert :vesting_start in fields
    assert {:error, :contracts_missing} = StocksLab.contracts(stocks, :v1)

    # An auction page's Finish button reaches its own version's launcher.
    assert {:ok, %{contract: factory, strategy: strategy}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :agent, contracts_version: :v2})

    assert factory == @revstake_v2["factory"]
    assert strategy == @revstake_v2["strategy"]

    assert {:ok, %{contract: launchpad, shape: %{version: :v2}}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :stocks, contracts_version: :v2})

    assert launchpad == @stocks_v2.launchpad

    assert {:ok, %{contract: @stocks_v3_launchpad}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :stocks, contracts_version: :v3})
  end

  test "a creator's vesting on the third launchpad runs 30 days from the graduation time" do
    launcher = 0x1414141414141414141414141414141414141414
    graduated = 1_800_000_000

    assert {:ok, %{starts_at: ^graduated, ends_at: ends_at, releasable: "1.5"}} =
             Pool.vesting(
               %{launcher: launcher, creator_released: 0, vesting_start: graduated},
               15 * 10 ** 17
             )

    assert ends_at - graduated == 30 * 86_400

    # Before graduation, and on the second launchpad, there are no fixed days.
    for record <- [
          %{launcher: launcher, creator_released: 0, vesting_start: 0},
          %{launcher: launcher, creator_released: 0, vesting_start_block: 40_000_000}
        ] do
      assert {:ok, vesting} = Pool.vesting(record, 0)
      refute Map.has_key?(vesting, :starts_at)
      refute Map.has_key?(vesting, :ends_at)
    end
  end
end
