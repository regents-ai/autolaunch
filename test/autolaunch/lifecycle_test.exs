defmodule Autolaunch.LifecycleTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Lifecycle

  describe "summary_flags/4" do
    test "prefers migration before sweeps once the migration block has been reached" do
      flags =
        Lifecycle.summary_flags(
          %{status: "ready"},
          %{
            address: "0xstrategy",
            migrated: false,
            migration_block: 105,
            sweep_block: 100,
            currency_balance: 12,
            token_balance: 9
          },
          %{releasable_launch_token: 5},
          110
        )

      assert flags.migrate_ready
      assert flags.currency_sweep_ready
      assert flags.token_sweep_ready
      assert flags.vesting_release_ready
      assert Lifecycle.recommended_action(flags) == "migrate"
    end

    test "returns wait when the job is not launch-ready yet" do
      flags =
        Lifecycle.summary_flags(
          %{status: "queued"},
          %{address: "0xstrategy", migration_block: 10, sweep_block: 10, currency_balance: 4},
          %{releasable_launch_token: 0},
          50
        )

      refute flags.migrate_ready
      refute flags.currency_sweep_ready
      refute flags.token_sweep_ready
      refute flags.vesting_release_ready
      assert Lifecycle.recommended_action(flags) == "wait"
    end

    test "falls through to vesting release when sweeps are empty" do
      flags =
        Lifecycle.summary_flags(
          %{status: "ready"},
          %{
            address: "0xstrategy",
            migrated: true,
            migration_block: 100,
            sweep_block: 90,
            currency_balance: 0,
            token_balance: "0"
          },
          %{releasable_launch_token: "2500"},
          120
        )

      refute flags.migrate_ready
      refute flags.currency_sweep_ready
      refute flags.token_sweep_ready
      assert flags.vesting_release_ready
      assert Lifecycle.recommended_action(flags) == "release_vesting"
    end
  end

  describe "prepare_scope_action/1" do
    test "maps the recommended action to the contract surface" do
      assert Lifecycle.prepare_scope_action("migrate") == {:ok, {"strategy", "migrate"}}
      assert Lifecycle.prepare_scope_action("sweep_currency") == {:ok, {"strategy", "sweep_currency"}}
      assert Lifecycle.prepare_scope_action("sweep_token") == {:ok, {"strategy", "sweep_token"}}
      assert Lifecycle.prepare_scope_action("release_vesting") == {:ok, {"vesting", "release"}}
      assert Lifecycle.prepare_scope_action("wait") == :noop
    end
  end
end
