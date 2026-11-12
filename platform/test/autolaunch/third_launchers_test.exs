defmodule Autolaunch.ThirdLaunchersTest do
  @moduledoc """
  Once the descriptions name Base's third Revstake factory and Memestock
  launchpad, new launches go to them on the third's schedule, and a launch
  made on the second is still read and finished through the second's own
  contracts.
  """

  use ExUnit.Case, async: false

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.{Lab, LaunchActions, Pool, ThirdLaunchers}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions

  @moduletag :tmp_dir
  @base 8453

  setup %{tmp_dir: dir} do
    second = %{revstake: Lab.current!(), stocks: StocksLab.current!()}
    ThirdLaunchers.install(dir)
    second
  end

  test "new launches go to the third launchers, on the third's schedule" do
    revstake = Lab.current!()
    stocks = StocksLab.current!()

    assert %{version: :v3} = revstake
    assert %{version: :v3} = stocks
    assert Lab.address!(revstake, :factory) == ThirdLaunchers.revstake()["factory"]
    assert StocksLab.address!(stocks, :launchpad) == ThirdLaunchers.stocks()["launchpad"]

    # The finisher and the discoveries drive the third launchers only.
    base = Enum.filter(Launchpads.configured(), &(&1.chain_id == @base))

    assert Enum.map(base, &{&1.launchpad, &1.contract}) == [
             {:base_revstake, ThirdLaunchers.revstake()["factory"]},
             {:base_memestock, ThirdLaunchers.stocks()["launchpad"]}
           ]

    assert [%{strategy: strategy}, %{shape: %{version: :v3}}] = base
    assert strategy == ThirdLaunchers.revstake()["strategy"]

    assert StocksLaunchActions.schedule(:base) == StocksLaunchActions.schedule(:base, :v3)
    assert LaunchActions.schedule() == LaunchActions.schedule(:v3)
  end

  test "a launch on the second launchers is read and finished through the second's contracts",
       %{revstake: second, stocks: second_stocks} do
    revstake = Lab.current!()
    assert {:ok, ^revstake} = Lab.contracts(revstake, :v3)
    assert {:ok, %{version: :v2} = earlier} = Lab.contracts(revstake, :v2)

    for key <- ~w(factory hook lp_locker strategy) do
      assert Lab.address!(earlier, key) == Lab.address!(second, key)
      assert Lab.abi!(earlier, key) == Lab.abi!(second, key)
    end

    # What both versions share is the description's own.
    assert Lab.address!(earlier, :regent) == Lab.address!(revstake, :regent)

    stocks = StocksLab.current!()
    assert {:ok, %{version: :v2} = earlier_pad} = StocksLab.contracts(stocks, :v2)

    for key <- ~w(launchpad hook locker bid_adapter)a,
        do: assert(Map.fetch!(earlier_pad, key) == StocksLab.address!(second_stocks, key))

    assert :vesting_start_block in earlier_pad.record_fields
    assert {:ok, %{version: :v3, record_fields: fields}} = StocksLab.contracts(stocks, :v3)
    assert :vesting_start in fields
    assert {:error, :contracts_missing} = StocksLab.contracts(stocks, :v1)

    # An auction page's Finish button reaches its own version's launcher.
    assert {:ok, %{contract: factory, strategy: strategy}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :agent, contracts_version: :v2})

    assert factory == Lab.address!(second, :factory)
    assert strategy == Lab.address!(second, :strategy)

    assert {:ok, %{contract: launchpad, shape: %{version: :v2}}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :stocks, contracts_version: :v2})

    assert launchpad == StocksLab.address!(second_stocks, :launchpad)

    assert {:ok, %{contract: third}} =
             Launchpads.for_auction(%{chain_id: @base, kind: :stocks, contracts_version: :v3})

    assert third == ThirdLaunchers.stocks()["launchpad"]
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
