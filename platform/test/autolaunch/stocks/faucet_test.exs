defmodule Autolaunch.Stocks.FaucetTest do
  # Changes the site's read-only setting and its chain, which every test reads.
  use ExUnit.Case, async: false

  alias Autolaunch.Stocks.Faucet

  @wallet "0x1111111111111111111111111111111111111111"
  @refused {:error, "Test funds are not available on this site."}

  setup do
    settings =
      for key <- [:prelaunch_read_only, :autolaunch_base_chain_id],
          do: {key, Application.fetch_env(:autolaunch, key)}

    on_exit(fn ->
      for {key, setting} <- settings do
        case setting do
          {:ok, value} -> Application.put_env(:autolaunch, key, value)
          :error -> Application.delete_env(:autolaunch, key)
        end
      end
    end)
  end

  # The test environment describes Base mainnet (chain 8453).
  test "a Base mainnet site gives no test funds, read-only or open" do
    for read_only <- [true, false] do
      Application.put_env(:autolaunch, :prelaunch_read_only, read_only)

      refute Faucet.available?()
      assert Faucet.regent(@wallet) == @refused
      assert Faucet.usdc(@wallet) == @refused
      assert Faucet.stock(@wallet, @wallet) == @refused
    end
  end

  test "a lab gives test funds only once it is open" do
    Application.put_env(:autolaunch, :autolaunch_base_chain_id, 31_337)

    Application.put_env(:autolaunch, :prelaunch_read_only, true)
    refute Faucet.available?()
    assert Faucet.regent(@wallet) == @refused
    assert Faucet.usdc(@wallet) == @refused
    assert Faucet.stock(@wallet, @wallet) == @refused

    Application.put_env(:autolaunch, :prelaunch_read_only, false)
    assert Faucet.available?()
    refute Faucet.regent(@wallet) == @refused
  end
end
