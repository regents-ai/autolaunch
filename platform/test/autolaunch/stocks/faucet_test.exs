defmodule Autolaunch.Stocks.FaucetTest do
  # Changes the site's read-only setting, which every test reads.
  use ExUnit.Case, async: false

  alias Autolaunch.Stocks.Faucet

  @wallet "0x1111111111111111111111111111111111111111"
  @refused {:error, "Test funds are not available on this site."}

  setup do
    setting = Application.fetch_env(:autolaunch, :prelaunch_read_only)

    on_exit(fn ->
      case setting do
        {:ok, value} -> Application.put_env(:autolaunch, :prelaunch_read_only, value)
        :error -> Application.delete_env(:autolaunch, :prelaunch_read_only)
      end
    end)
  end

  # The test environment describes Base mainnet (chain 8453), so no press sends
  # anything, whether the site is read-only or open.
  test "a Base mainnet site gives no test funds, read-only or open" do
    for read_only <- [true, false] do
      Application.put_env(:autolaunch, :prelaunch_read_only, read_only)

      refute Faucet.available?()
      assert Faucet.regent(@wallet) == @refused
      assert Faucet.usdc(@wallet) == @refused
      assert Faucet.stock(@wallet, @wallet) == @refused
    end
  end
end
