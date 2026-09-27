defmodule Autolaunch.AuctionFinish.WalletTest do
  use ExUnit.Case, async: true

  alias Autolaunch.AuctionFinish.Wallet

  # Anvil's public test account 9, from the well-known "test … junk" mnemonic.
  @key "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"

  # A wrong byte here and no ended auction is ever finished: the chain refuses
  # the transaction, or accepts it under a hash other than the one recorded.
  # The reference is Foundry's own signing of the same call:
  #   cast mktx --private-key <key> --chain 46630 --nonce 7 --gas-limit 400000 \
  #     --priority-gas-price 1000000 --gas-price 3000000000 \
  #     0x635615ccef2ef24d0655fc2ebc47a14e005fef6e 'migrate(uint256)' 12
  test "a finishing transaction is byte for byte the one Foundry signs, under the same hash" do
    {:ok, wallet} = Wallet.new(@key)
    assert wallet.address == "0xa0ee7a142d267c1f36714e4a8f75612f20a79720"
    refute inspect(wallet) =~ "private_key"

    assert Wallet.sign(wallet, %{
             chain_id: 46_630,
             nonce: 7,
             max_priority_fee: 1_000_000,
             max_fee: 3_000_000_000,
             gas_limit: 400_000,
             to: "0x635615ccef2ef24d0655fc2ebc47a14e005fef6e",
             data: "0x454b0608000000000000000000000000000000000000000000000000000000000000000c"
           }) ==
             {"0x02f89082b62607830f424084b2d05e0083061a8094635615ccef2ef24d0655fc2ebc47a14e005fef6e80a4454b0608000000000000000000000000000000000000000000000000000000000000000cc080a08f6063144570362336ad088d9d6711ffffc69e77b28573122039fd5c1c16a477a00b37acc31cb5e5d1d99c0a662417dd89ed7852eeabdbe4cc2da34ac8fbf5554b",
              "0x52ed7a617d5cebcff09e20ed6ff7add00c024b891a068d3abc6c612ad33204b1"}
  end
end
