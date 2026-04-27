defmodule Autolaunch.RegentStakingTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.RegentStaking

  @contract "0x9999999999999999999999999999999999999999"
  @stake_token "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @usdc "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  @treasury "0xcccccccccccccccccccccccccccccccccccccccc"
  @owner "0xdddddddddddddddddddddddddddddddddddddddd"
  @wallet "0x1111111111111111111111111111111111111111"
  @base_sepolia_chain_id 84_532
  @base_chain_id 8_453

  setup do
    previous_adapter = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_config = Application.get_env(:autolaunch, :regent_staking, [])

    Application.put_env(:autolaunch, :cca_rpc_adapter, __MODULE__.FakeRpc)

    Application.put_env(
      :autolaunch,
      :regent_staking,
      chain_id: @base_sepolia_chain_id,
      chain_label: "Base Sepolia",
      rpc_url: "https://base-sepolia.example",
      contract_address: @contract
    )

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_adapter)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      Application.put_env(:autolaunch, :regent_staking, previous_config)
    end)

    {:ok, human: %HumanUser{wallet_address: @wallet, wallet_addresses: [@wallet]}}
  end

  test "overview returns live contract and wallet state", %{human: human} do
    assert {:ok, state} = RegentStaking.overview(human)

    assert state.chain_id == @base_sepolia_chain_id
    assert state.contract_address == @contract
    assert state.stake_token_address == @stake_token
    assert state.usdc_address == @usdc
    assert state.owner_address == @owner
    assert state.treasury_recipient == @treasury
    assert state.staker_share_bps == 7000
    assert state.total_staked == "500"
    assert state.total_usdc_received == "1000"
    assert state.direct_deposit_usdc == "1000"
    assert state.treasury_residual_usdc == "150"
    assert state.materialized_outstanding == "3"
    assert state.available_reward_inventory == "8"
    assert state.total_claimed_so_far == "5"
    assert state.wallet_stake_balance == "20"
    assert state.wallet_claimable_usdc == "12"
    assert state.wallet_claimable_regent == "4"
    assert state.wallet_funded_claimable_regent == "2"
  end

  test "obligation_metrics computes exact accrued totals from a provided staker list" do
    assert {:ok, metrics} =
             RegentStaking.obligation_metrics([
               "0x1111111111111111111111111111111111111111",
               "0x2222222222222222222222222222222222222222"
             ])

    assert metrics.staker_count == 2
    assert metrics.exact_total_accrued_obligations == "7"
    assert metrics.materialized_outstanding == "3"
    assert metrics.available_reward_inventory == "8"
    assert metrics.total_claimed_so_far == "5"
    assert metrics.accrued_but_unsynced == "4"
    assert metrics.funding_gap == "0"
  end

  test "stake returns a canonical wallet tx request", %{human: human} do
    assert {:ok, %{tx_request: tx_request}} = RegentStaking.stake(%{"amount" => "1.5"}, human)

    assert tx_request.chain_id == @base_sepolia_chain_id
    assert tx_request.to == @contract
    assert String.starts_with?(tx_request.data, "0x7acb7757")
  end

  test "stake uses the configured staking chain id", %{human: human} do
    Application.put_env(
      :autolaunch,
      :regent_staking,
      chain_id: 12_345,
      chain_label: "Custom Base Test",
      rpc_url: "https://custom-base.example",
      contract_address: @contract
    )

    assert {:ok, %{tx_request: tx_request}} = RegentStaking.stake(%{"amount" => "1.5"}, human)
    assert tx_request.chain_id == 12_345
  end

  test "prepare_deposit_usdc encodes ascii source tags and refs" do
    assert {:ok, %{prepared: prepared}} =
             RegentStaking.prepare_deposit_usdc(%{
               "amount" => "250.5",
               "source_tag" => "base_manual",
               "source_ref" => "2026-03"
             })

    assert prepared.resource == "regent_staking"
    assert prepared.action == "deposit_usdc"
    assert prepared.chain_id == @base_sepolia_chain_id
    assert prepared.target == @contract
    assert String.starts_with?(prepared.calldata, "0x7dc6bb98")
  end

  test "prepared actions use Base as the canonical staking rail when chain config is omitted" do
    Application.put_env(
      :autolaunch,
      :regent_staking,
      rpc_url: "https://base.example",
      contract_address: @contract
    )

    assert {:ok, %{prepared: prepared}} =
             RegentStaking.prepare_deposit_usdc(%{
               "amount" => "1",
               "source_tag" => "manual",
               "source_ref" => "default"
             })

    assert prepared.chain_id == @base_chain_id
    assert prepared.tx_request.chain_id == @base_chain_id
  end

  test "prepare_withdraw_treasury defaults recipient to the configured treasury" do
    assert {:ok, %{prepared: prepared}} =
             RegentStaking.prepare_withdraw_treasury(%{"amount" => "10"})

    assert prepared.action == "withdraw_treasury"
    assert prepared.params.recipient == @treasury
    assert String.starts_with?(prepared.calldata, "0xe13b5822")
  end

  test "overview fails cleanly when the rail is unconfigured" do
    Application.put_env(
      :autolaunch,
      :regent_staking,
      chain_id: @base_sepolia_chain_id,
      chain_label: "Base Sepolia"
    )

    assert {:error, :unconfigured} = RegentStaking.overview(nil)
  end

  defmodule FakeRpc do
    @contract "0x9999999999999999999999999999999999999999"
    @stake_token "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    @usdc "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    @treasury "0xcccccccccccccccccccccccccccccccccccccccc"
    @owner "0xdddddddddddddddddddddddddddddddddddddddd"

    def block_number(_chain_id, _opts), do: {:ok, 1}
    def tx_receipt(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def tx_by_hash(_chain_id, _tx_hash, _opts), do: {:ok, nil}
    def get_logs(_chain_id, _filter, _opts), do: {:ok, []}

    def eth_call(_chain_id, to, data, _opts) do
      case {String.downcase(to), String.slice(data, 0, 10)} do
        {contract, "0x8da5cb5b"} when contract == @contract ->
          {:ok, address_word(@owner)}

        {contract, "0x51ed6a30"} when contract == @contract ->
          {:ok, address_word(@stake_token)}

        {contract, "0x3e413bee"} when contract == @contract ->
          {:ok, address_word(@usdc)}

        {contract, "0xeb4eebc7"} when contract == @contract ->
          {:ok, address_word(@treasury)}

        {contract, "0x53dfb983"} when contract == @contract ->
          {:ok, uint_word(7000)}

        {contract, "0x5c975abb"} when contract == @contract ->
          {:ok, uint_word(0)}

        {contract, "0x817b1cd2"} when contract == @contract ->
          {:ok, uint_word(500 * 1_000_000_000_000_000_000)}

        {contract, "0x966ed108"} when contract == @contract ->
          {:ok, uint_word(150_000_000)}

        {contract, "0xcf51bfdd"} when contract == @contract ->
          {:ok, uint_word(1_000_000_000)}

        {contract, "0x6a142340"} when contract == @contract ->
          {:ok, uint_word(1_000_000_000)}

        {contract, "0xa8e345dd"} when contract == @contract ->
          {:ok, uint_word(3 * 1_000_000_000_000_000_000)}

        {contract, "0xe2cfe6b9"} when contract == @contract ->
          {:ok, uint_word(8 * 1_000_000_000_000_000_000)}

        {contract, "0x4cbf5721"} when contract == @contract ->
          {:ok, uint_word(5 * 1_000_000_000_000_000_000)}

        {contract, "0x60217267"} when contract == @contract ->
          {:ok, uint_word(20 * 1_000_000_000_000_000_000)}

        {contract, "0xb026ee79"} when contract == @contract ->
          {:ok, uint_word(12_000_000)}

        {contract, "0xf653a7f7" <> _address_word} when contract == @contract ->
          {:ok, uint_word(preview_claimable_regent(data))}

        {contract, "0xb4010d49" <> _address_word} when contract == @contract ->
          {:ok, uint_word(2 * 1_000_000_000_000_000_000)}

        {token, "0x70a08231"} when token == @stake_token ->
          {:ok, uint_word(123 * 1_000_000_000_000_000_000)}

        _ ->
          {:error, :unexpected_call}
      end
    end

    defp uint_word(value) do
      "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")
    end

    defp address_word(address) do
      "0x" <>
        (address
         |> String.downcase()
         |> String.trim_leading("0x")
         |> String.pad_leading(64, "0"))
    end

    defp preview_claimable_regent(<<"0xf653a7f7", encoded::binary>>) do
      case String.slice(encoded, -40, 40) |> String.downcase() do
        "1111111111111111111111111111111111111111" -> 4 * 1_000_000_000_000_000_000
        "2222222222222222222222222222222222222222" -> 3 * 1_000_000_000_000_000_000
        _ -> 0
      end
    end
  end
end
