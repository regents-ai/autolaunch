defmodule AutolaunchWeb.RegentStatusTest do
  use ExUnit.Case, async: false

  alias AutolaunchWeb.RegentStatus

  defmodule StakingStub do
    def overview(_current_human) do
      {:ok,
       %{
         paused: false,
         chain_label: "Base",
         total_staked: "49999944.24",
         total_usdc_received: "1000000",
         wallet_claimable_usdc: "1000000",
         wallet_funded_claimable_regent: "2499999.5"
       }}
    end
  end

  setup do
    original = Application.get_env(:autolaunch, :regent_status, [])
    Application.put_env(:autolaunch, :regent_status, regent_staking_module: StakingStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :regent_status, original)
    end)
  end

  test "compacts large staking values in the shell header" do
    status =
      RegentStatus.snapshot(%{wallet_address: "0x1111111111111111111111111111111111111111"})

    assert status.headline == "$REGENT 50.0M staked"
    assert status.detail == "Wallet can claim 1.0M USDC and 2.5M REGENT."
  end
end
