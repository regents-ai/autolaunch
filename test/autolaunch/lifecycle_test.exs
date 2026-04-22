defmodule Autolaunch.LifecycleTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Lifecycle

  @agent_safe "0x1111111111111111111111111111111111111111"

  describe "settlement_summary/8" do
    test "classifies a ready migration when the strategy already holds the proceeds" do
      summary =
        Lifecycle.settlement_summary(
          %{status: "ready", agent_safe_address: @agent_safe},
          %{
            address: "0xstrategy",
            migrated: false,
            migration_block: 105,
            sweep_block: 150,
            currency_balance: 12,
            token_balance: 9
          },
          %{token_balance: 0, currency_balance: 0, graduated: true},
          %{releasable_launch_token: 0},
          accepted_card(),
          accepted_card(),
          accepted_card(),
          110
        )

      assert summary.settlement_state == "awaiting_migration"
      assert summary.recommended_action == "migrate"
      assert summary.allowed_actions == ["migrate"]
      assert summary.required_actor == "operator"
      assert summary.balance_snapshot.strategy.usdc_balance == 12
    end

    test "classifies auction asset return before migration when proceeds remain in the auction" do
      summary =
        Lifecycle.settlement_summary(
          %{status: "ready", agent_safe_address: @agent_safe},
          %{
            address: "0xstrategy",
            migrated: false,
            migration_block: 105,
            sweep_block: 150,
            currency_balance: 0,
            token_balance: 50
          },
          %{token_balance: 20, currency_balance: 30, graduated: true},
          %{releasable_launch_token: 0},
          accepted_card(),
          accepted_card(),
          accepted_card(),
          110
        )

      assert summary.settlement_state == "awaiting_auction_asset_return"
      assert summary.recommended_action == "auction_sweep_currency"
      assert summary.allowed_actions == ["auction_sweep_currency", "auction_sweep_unsold_tokens"]
      assert summary.blocked_reason =~ "returned before migration"
    end

    test "classifies a failed auction recovery after the sweep block" do
      summary =
        Lifecycle.settlement_summary(
          %{status: "ready", agent_safe_address: @agent_safe},
          %{
            address: "0xstrategy",
            migrated: false,
            migration_block: 105,
            sweep_block: 150,
            currency_balance: 0,
            token_balance: 50
          },
          %{token_balance: 20, currency_balance: 0, graduated: false},
          %{releasable_launch_token: 0},
          accepted_card(),
          accepted_card(),
          accepted_card(),
          160
        )

      assert summary.settlement_state == "failed_auction_recoverable"
      assert summary.recommended_action == "recover_failed_auction"
      assert summary.allowed_actions == ["recover_failed_auction"]
    end

    test "marks ownership acceptance as the next step after settlement is otherwise complete" do
      summary =
        Lifecycle.settlement_summary(
          %{status: "ready", agent_safe_address: @agent_safe},
          %{
            address: "0xstrategy",
            migrated: true,
            migration_block: 105,
            sweep_block: 150,
            currency_balance: 0,
            token_balance: 0
          },
          %{token_balance: 0, currency_balance: 0, graduated: true},
          %{releasable_launch_token: 0},
          pending_card("accept_fee_registry_ownership"),
          pending_card("accept_fee_vault_ownership"),
          accepted_card(),
          160
        )

      assert summary.settlement_state == "ownership_acceptance_required"
      assert summary.recommended_action == "accept_fee_registry_ownership"

      assert summary.allowed_actions == [
               "accept_fee_registry_ownership",
               "accept_fee_vault_ownership"
             ]

      assert summary.required_actor == "agent_safe"
    end
  end

  describe "prepare_scope_action/1" do
    test "maps settlement actions to the contract surface" do
      assert Lifecycle.prepare_scope_action("migrate") == {:ok, {"strategy", "migrate"}}

      assert Lifecycle.prepare_scope_action("auction_sweep_currency") ==
               {:ok, {"auction", "sweep_currency"}}

      assert Lifecycle.prepare_scope_action("auction_sweep_unsold_tokens") ==
               {:ok, {"auction", "sweep_unsold_tokens"}}

      assert Lifecycle.prepare_scope_action("recover_failed_auction") ==
               {:ok, {"strategy", "recover_failed_auction"}}

      assert Lifecycle.prepare_scope_action("accept_fee_registry_ownership") ==
               {:ok, {"fee_registry", "accept_ownership"}}

      assert Lifecycle.prepare_scope_action("accept_fee_vault_ownership") ==
               {:ok, {"fee_vault", "accept_ownership"}}

      assert Lifecycle.prepare_scope_action("accept_hook_ownership") ==
               {:ok, {"hook", "accept_ownership"}}

      assert Lifecycle.prepare_scope_action("sweep_currency") ==
               {:ok, {"strategy", "sweep_currency"}}

      assert Lifecycle.prepare_scope_action("sweep_token") == {:ok, {"strategy", "sweep_token"}}
      assert Lifecycle.prepare_scope_action("release_vesting") == {:ok, {"vesting", "release"}}
      assert Lifecycle.prepare_scope_action("wait") == :noop
      assert Lifecycle.prepare_scope_action("not_real") == {:error, :unsupported_action}
    end
  end

  defp accepted_card do
    %{
      address: "0xcard",
      owner: @agent_safe,
      pending_owner: nil
    }
  end

  defp pending_card(_action) do
    %{
      address: "0xcard",
      owner: "0x2222222222222222222222222222222222222222",
      pending_owner: @agent_safe
    }
  end
end
