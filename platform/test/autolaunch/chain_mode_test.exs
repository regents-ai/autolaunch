defmodule Autolaunch.ChainModeTest do
  use ExUnit.Case, async: true

  alias Autolaunch.ChainMode

  test "AUTOLAUNCH_CHAIN_MODE admits base and fork only, and only fork opens writes" do
    assert ChainMode.parse!(nil) == :base
    assert ChainMode.parse!("") == :base
    assert ChainMode.parse!("base") == :base
    assert ChainMode.parse!("fork") == :fork

    for value <- ["Fork", "preview", "anvil", "true"] do
      assert_raise ArgumentError, ~r/AUTOLAUNCH_CHAIN_MODE must be base or fork/, fn ->
        ChainMode.parse!(value)
      end
    end

    assert ChainMode.prelaunch_read_only?(:fork) == false
    assert ChainMode.prelaunch_read_only?(:base) == true

    assert ChainMode.label(:fork) == "Preview on a Base fork"
    assert ChainMode.label(:base) == "Local Base fork"

    # The test environment runs in base mode, so today's fail-closed default holds.
    assert ChainMode.mode() == :base
    assert Autolaunch.Prelaunch.read_only?()
  end

  test "the faucet cooldown defaults to an hour on a fork preview and none on a lab" do
    assert ChainMode.faucet_cooldown_seconds!(:fork, nil) == 3_600
    assert ChainMode.faucet_cooldown_seconds!(:base, nil) == 0
    assert ChainMode.faucet_cooldown_seconds!(:fork, "0") == 0
    assert ChainMode.faucet_cooldown_seconds!(:base, "90") == 90

    for value <- ["-1", "1.5", "soon", "60s"] do
      assert_raise ArgumentError, ~r/AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS/, fn ->
        ChainMode.faucet_cooldown_seconds!(:fork, value)
      end
    end
  end
end
