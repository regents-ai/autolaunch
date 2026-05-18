defmodule Mix.Tasks.Autolaunch.BetaCheckTest do
  use Autolaunch.DataCase, async: false

  import ExUnit.CaptureIO

  defmodule LaunchStub do
    def list_auctions(%{"mode" => "all", "sort" => "newest"}, nil), do: []
  end

  defmodule RegentStakingStub do
    def overview(nil),
      do: {:ok, %{contract_address: "0x1111111111111111111111111111111111111111"}}
  end

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_regent_staking = Application.get_env(:autolaunch, :regent_staking, [])
    previous_beta_readiness = Application.get_env(:autolaunch, :beta_readiness, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch,
        chain_id: 8_453,
        rpc_url: "https://base.example",
        cca_factory_address: "0x1111111111111111111111111111111111111111",
        pool_manager_address: "0x2222222222222222222222222222222222222222",
        position_manager_address: "0x3333333333333333333333333333333333333333",
        auction_quote_token_address: "0x4444444444444444444444444444444444444444",
        revenue_usdc_address: "0x4545454545454545454545454545454545454545",
        revenue_share_factory_address: "0x5555555555555555555555555555555555555555",
        revenue_ingress_factory_address: "0x6666666666666666666666666666666666666666",
        lbp_strategy_factory_address: "0x7777777777777777777777777777777777777777",
        token_factory_address: "0x8888888888888888888888888888888888888888",
        identity_registry_address: "0x9999999999999999999999999999999999999999",
        factory_owner_address: "0x9999999999999999999999999999999999999997",
        strategy_operator: "0x9999999999999999999999999999999999999998",
        official_pool_fee: "0",
        official_pool_tick_spacing: "60",
        cca_tick_spacing_q96: "79228162514264337593543950",
        cca_floor_price_q96: "7922816251426433759354395000",
        auction_duration_blocks: "9258",
        cca_prebid_blocks: "0",
        cca_final_block_bps: "3000",
        cca_start_block_offset: "300",
        cca_claim_block_offset: "64",
        lbp_migration_block_offset: "128",
        lbp_sweep_block_offset: "256"
      )
    )

    Application.put_env(:autolaunch, :regent_staking,
      chain_id: 8_453,
      rpc_url: "https://base-staking.example",
      contract_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )

    Application.put_env(:autolaunch, :beta_readiness,
      launch_module: LaunchStub,
      regent_staking_module: RegentStakingStub
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
      Application.put_env(:autolaunch, :regent_staking, previous_regent_staking)
      Application.put_env(:autolaunch, :beta_readiness, previous_beta_readiness)
    end)

    Mix.Task.reenable("autolaunch.beta_check")
    :ok
  end

  test "beta check task prints a success footer" do
    output =
      capture_io(fn ->
        Mix.Tasks.Autolaunch.BetaCheck.run([])
      end)

    assert output =~ "Autolaunch beta check passed."
  end
end
