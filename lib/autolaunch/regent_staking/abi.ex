defmodule Autolaunch.RegentStaking.Abi do
  @moduledoc false

  @selectors %{
    owner: "0x8da5cb5b",
    stake_token: "0x51ed6a30",
    usdc: "0x3e413bee",
    treasury_recipient: "0xeb4eebc7",
    staker_share_bps: "0x53dfb983",
    paused: "0x5c975abb",
    total_staked: "0x817b1cd2",
    staked_balance: "0x60217267",
    preview_claimable_usdc: "0xb026ee79",
    treasury_residual_usdc: "0x966ed108",
    total_recognized_rewards_usdc: "0x92bfc075",
    balance_of: "0x70a08231",
    stake: "0x7acb7757",
    unstake: "0x8381e182",
    claim_usdc: "0x42852610",
    deposit_usdc: "0x7dc6bb98",
    withdraw_treasury_residual: "0xe13b5822"
  }

  def selector(name), do: Map.fetch!(@selectors, name)

  def encode_call(name, args \\ []) when is_list(args) do
    selector(name) <> Enum.map_join(args, "", &encode_arg/1)
  end

  def encode_stake(amount, receiver),
    do: encode_call(:stake, [{:uint256, amount}, {:address, receiver}])

  def encode_unstake(amount, recipient),
    do: encode_call(:unstake, [{:uint256, amount}, {:address, recipient}])

  def encode_claim_usdc(recipient), do: encode_call(:claim_usdc, [{:address, recipient}])

  def encode_deposit_usdc(amount, source_tag, source_ref) do
    encode_call(
      :deposit_usdc,
      [{:uint256, amount}, {:bytes32, source_tag}, {:bytes32, source_ref}]
    )
  end

  def encode_withdraw_treasury_residual(amount, recipient) do
    encode_call(:withdraw_treasury_residual, [{:uint256, amount}, {:address, recipient}])
  end

  def encode_address_call(name, address), do: encode_call(name, [{:address, address}])

  def decode_uint256(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    String.to_integer(hex, 16)
  end

  def decode_address(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    "0x" <> String.slice(String.downcase(hex), -40, 40)
  end

  def decode_bool(<<"0x", hex::binary>>) when byte_size(hex) == 64 do
    String.to_integer(hex, 16) != 0
  end

  defp encode_arg({:uint256, value}) when is_integer(value) and value >= 0 do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
  end

  defp encode_arg({:address, "0x" <> address}) when byte_size(address) == 40 do
    address
    |> String.downcase()
    |> String.pad_leading(64, "0")
  end

  defp encode_arg({:bytes32, "0x" <> value}) when byte_size(value) == 64 do
    String.downcase(value)
  end
end
