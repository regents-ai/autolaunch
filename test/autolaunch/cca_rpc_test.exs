defmodule Autolaunch.CCARpcTest do
  use ExUnit.Case, async: false

  alias Autolaunch.CCA.Rpc

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_regent_staking = Application.get_env(:autolaunch, :regent_staking, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch, chain_id: 8_453, rpc_url: "https://base.example")
    )

    Application.put_env(
      :autolaunch,
      :regent_staking,
      chain_id: 84_532,
      chain_label: "Base Sepolia",
      rpc_url: "https://base-sepolia.example",
      contract_address: "0x9999999999999999999999999999999999999999"
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :regent_staking, previous_regent_staking)
    end)

    :ok
  end

  test "rpc_url resolves the configured staking chain" do
    assert {:ok, "https://base-sepolia.example"} = Rpc.rpc_url(84_532)
    assert {:ok, "https://base.example"} = Rpc.rpc_url(8_453)
  end

  test "rpc_url keeps Base launch routing unchanged" do
    assert {:ok, "https://base.example"} = Rpc.rpc_url(8_453)
  end

  test "rpc_url can resolve the staking RPC when launch and staking share the same chain id" do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_regent_staking = Application.get_env(:autolaunch, :regent_staking, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch, chain_id: 84_532, rpc_url: "https://launch-shared.example")
    )

    Application.put_env(
      :autolaunch,
      :regent_staking,
      Keyword.merge(previous_regent_staking,
        chain_id: 84_532,
        rpc_url: "https://staking-shared.example"
      )
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :regent_staking, previous_regent_staking)
    end)

    assert {:ok, "https://launch-shared.example"} = Rpc.rpc_url(84_532)

    assert {:ok, "https://staking-shared.example"} =
             Rpc.rpc_url(84_532, source: :regent_staking)
  end
end
