defmodule Autolaunch.Lifecycle do
  @moduledoc false

  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts
  alias Autolaunch.Launch

  def job_summary(job_id, current_human \\ nil) do
    with {:ok, response} <- Launch.get_job_response(job_id),
         {:ok, contract_scope} <- Contracts.job_state_from_response(response, current_human) do
      job = response.job
      current_block = contract_scope.current_block || current_block(job.chain_id)
      strategy = contract_scope.strategy || %{}
      auction = contract_scope.auction || %{}
      vesting = contract_scope.vesting || %{}

      settlement =
        settlement_summary(
          job,
          strategy,
          auction,
          vesting,
          contract_scope.fee_registry || %{},
          contract_scope.fee_vault || %{},
          contract_scope.hook || %{},
          current_block
        )

      {:ok,
       %{
         job: response.job,
         auction: merge_launch_auction(response.auction, auction),
         strategy: strategy,
         vesting: vesting,
         current_block: current_block
       }}
      |> then(&Map.merge(&1, settlement))
    end
  end

  def prepare_finalize(job_id, current_human \\ nil) do
    with {:ok, summary} <- job_summary(job_id, current_human) do
      prepared = prepare_action(summary.job, summary.recommended_action)

      case prepared do
        {:ok, payload} -> {:ok, Map.put(summary, :prepared, Map.get(payload, :prepared))}
        {:error, _} = error -> error
      end
    end
  end

  def register_finalize(job_id, attrs, current_human \\ nil) do
    with {:ok, tx_hash} <- tx_hash_param(attrs),
         {:ok, summary} <- job_summary(job_id, current_human) do
      {:ok,
       %{
         job_id: job_id,
         tx_hash: tx_hash,
         recommended_action: summary.recommended_action,
         settlement_state: summary.settlement_state,
         status: "submitted",
         next_summary: summary
       }}
    end
  end

  def vesting_status(job_id, current_human \\ nil) do
    with {:ok, summary} <- job_summary(job_id, current_human) do
      {:ok,
       %{
         job_id: job_id,
         vesting_wallet_address: summary.job.vesting_wallet_address,
         releasable_launch_token: summary.vesting[:releasable_launch_token],
         released_launch_token: summary.vesting[:released_launch_token],
         beneficiary: summary.vesting[:beneficiary],
         start_timestamp: summary.vesting[:start_timestamp],
         duration_seconds: summary.vesting[:duration_seconds],
         release_ready: positive_uint?(summary.vesting[:releasable_launch_token])
       }}
    end
  end

  def settlement_summary(
        job,
        strategy,
        auction,
        vesting,
        fee_registry,
        fee_vault,
        hook,
        current_block
      ) do
    ready_with_strategy? = job_ready_with_strategy?(job, strategy)
    migrated? = truthy?(strategy[:migrated])
    migration_block_reached? = block_reached?(current_block, strategy[:migration_block])
    sweep_block_reached? = block_reached?(current_block, strategy[:sweep_block])
    vesting_release_ready = positive_uint?(vesting[:releasable_launch_token])
    ownership_status = ownership_status(job, fee_registry, fee_vault, hook)
    balance_snapshot = balance_snapshot(strategy, auction)

    auction_asset_actions =
      auction_asset_actions(auction, migrated?, migration_block_reached?)

    failed_auction_recoverable? =
      ready_with_strategy? and !migrated? and sweep_block_reached? and
        auction_graduated?(auction) == false and
        (positive_uint?(auction[:token_balance]) or positive_uint?(strategy[:token_balance]))

    post_recovery_cleanup? =
      ready_with_strategy? and !migrated? and sweep_block_reached? and
        auction_graduated?(auction) == false and
        !positive_uint?(auction[:token_balance]) and !positive_uint?(strategy[:token_balance]) and
        (positive_uint?(auction[:currency_balance]) or positive_uint?(strategy[:currency_balance]))

    awaiting_migration? =
      ready_with_strategy? and !migrated? and migration_block_reached? and
        positive_uint?(strategy[:currency_balance]) and auction_asset_actions == []

    sweep_actions =
      sweep_actions(strategy, migrated?, sweep_block_reached?)

    settled? =
      settled?(
        ready_with_strategy?,
        migrated?,
        sweep_block_reached?,
        sweep_actions,
        failed_auction_recoverable?,
        post_recovery_cleanup?,
        auction_asset_actions,
        strategy,
        auction
      )

    wait_blocked_reason =
      wait_blocked_reason(
        job,
        strategy,
        current_block,
        ready_with_strategy?,
        migrated?,
        migration_block_reached?,
        sweep_block_reached?
      )

    {settlement_state, blocked_reason, allowed_actions} =
      cond do
        !ready_with_strategy? ->
          {"wait", wait_blocked_reason, release_actions(vesting_release_ready)}

        failed_auction_recoverable? ->
          {"failed_auction_recoverable", nil, ["recover_failed_auction"]}

        auction_asset_actions != [] ->
          {
            "awaiting_auction_asset_return",
            "Auction balances still need to be returned before migration.",
            auction_asset_actions
          }

        awaiting_migration? ->
          {"awaiting_migration", nil, ["migrate"]}

        sweep_actions != [] ->
          {"awaiting_sweeps", nil, sweep_actions}

        post_recovery_cleanup? ->
          {
            "post_recovery_cleanup",
            "Token recovery is finished, but leftover currency still needs review.",
            release_actions(vesting_release_ready)
          }

        ownership_status.pending_actions != [] ->
          {
            "ownership_acceptance_required",
            "Fee contract ownership still needs to be accepted by the Agent Safe.",
            ownership_status.pending_actions ++ release_actions(vesting_release_ready)
          }

        settled? ->
          {"settled", nil, release_actions(vesting_release_ready)}

        true ->
          {"wait", wait_blocked_reason, release_actions(vesting_release_ready)}
      end

    recommended_action = List.first(allowed_actions) || "wait"

    %{
      settlement_state: settlement_state,
      blocked_reason: blocked_reason,
      recommended_action: recommended_action,
      allowed_actions: allowed_actions,
      required_actor: required_actor(recommended_action),
      balance_snapshot: balance_snapshot,
      ownership_status: ownership_status
    }
  end

  def prepare_scope_action("migrate"), do: {:ok, {"strategy", "migrate"}}
  def prepare_scope_action("auction_sweep_currency"), do: {:ok, {"auction", "sweep_currency"}}

  def prepare_scope_action("auction_sweep_unsold_tokens"),
    do: {:ok, {"auction", "sweep_unsold_tokens"}}

  def prepare_scope_action("recover_failed_auction"),
    do: {:ok, {"strategy", "recover_failed_auction"}}

  def prepare_scope_action("sweep_currency"), do: {:ok, {"strategy", "sweep_currency"}}
  def prepare_scope_action("sweep_token"), do: {:ok, {"strategy", "sweep_token"}}

  def prepare_scope_action("accept_fee_registry_ownership"),
    do: {:ok, {"fee_registry", "accept_ownership"}}

  def prepare_scope_action("accept_fee_vault_ownership"),
    do: {:ok, {"fee_vault", "accept_ownership"}}

  def prepare_scope_action("accept_hook_ownership"), do: {:ok, {"hook", "accept_ownership"}}
  def prepare_scope_action("release_vesting"), do: {:ok, {"vesting", "release"}}
  def prepare_scope_action("wait"), do: :noop
  def prepare_scope_action(_action), do: {:error, :unsupported_action}

  defp prepare_action(job, action) do
    case prepare_scope_action(action) do
      {:ok, {scope, action_name}} ->
        Contracts.prepare_job_action_for_job(job, scope, action_name, %{})

      :noop ->
        {:ok, %{job_id: job.job_id, prepared: nil}}

      {:error, _} = error ->
        error
    end
  end

  defp job_ready_with_strategy?(job, strategy),
    do: job.status == "ready" and present?(strategy[:address])

  defp current_block(chain_id) do
    case Rpc.block_number(chain_id) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp block_reached?(current_block, target)
       when is_integer(current_block) and is_integer(target),
       do: current_block >= target

  defp block_reached?(_current_block, _target), do: false

  defp positive_uint?(value) when is_integer(value), do: value > 0
  defp positive_uint?(value) when is_binary(value), do: value not in ["", "0", "0x0"]
  defp positive_uint?(_value), do: false

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(_value), do: false

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp auction_asset_actions(auction, migrated?, migration_block_reached?) do
    if migrated? or !migration_block_reached? do
      []
    else
      []
      |> maybe_add_action(
        auction_graduated?(auction) == true and positive_uint?(auction[:currency_balance]),
        "auction_sweep_currency"
      )
      |> maybe_add_action(positive_uint?(auction[:token_balance]), "auction_sweep_unsold_tokens")
    end
  end

  defp sweep_actions(strategy, migrated?, sweep_block_reached?) do
    if migrated? and sweep_block_reached? do
      []
      |> maybe_add_action(positive_uint?(strategy[:currency_balance]), "sweep_currency")
      |> maybe_add_action(positive_uint?(strategy[:token_balance]), "sweep_token")
    else
      []
    end
  end

  defp release_actions(true), do: ["release_vesting"]
  defp release_actions(false), do: []

  defp maybe_add_action(actions, true, action), do: actions ++ [action]
  defp maybe_add_action(actions, false, _action), do: actions

  defp required_actor("release_vesting"), do: "beneficiary"
  defp required_actor(action) when action in ["wait", nil], do: nil

  defp required_actor(action)
       when action in [
              "accept_fee_registry_ownership",
              "accept_fee_vault_ownership",
              "accept_hook_ownership"
            ],
       do: "agent_safe"

  defp required_actor(_action), do: "operator"

  defp balance_snapshot(strategy, auction) do
    %{
      strategy: %{
        token_balance: strategy[:token_balance],
        usdc_balance: strategy[:currency_balance]
      },
      auction: %{
        token_balance: auction[:token_balance],
        usdc_balance: auction[:currency_balance]
      }
    }
  end

  defp ownership_status(job, fee_registry, fee_vault, hook) do
    items = %{
      fee_registry:
        ownership_item(
          fee_registry[:address],
          fee_registry[:owner],
          fee_registry[:pending_owner],
          job.agent_safe_address,
          "accept_fee_registry_ownership"
        ),
      fee_vault:
        ownership_item(
          fee_vault[:address],
          fee_vault[:owner],
          fee_vault[:pending_owner],
          job.agent_safe_address,
          "accept_fee_vault_ownership"
        ),
      hook:
        ownership_item(
          hook[:address],
          hook[:owner],
          hook[:pending_owner],
          job.agent_safe_address,
          "accept_hook_ownership"
        )
    }

    pending_actions =
      items
      |> Map.values()
      |> Enum.flat_map(fn
        %{action: action, accepted: false, status: "pending_acceptance"} -> [action]
        _ -> []
      end)

    %{
      fee_registry: items.fee_registry,
      fee_vault: items.fee_vault,
      hook: items.hook,
      pending_actions: pending_actions,
      all_accepted: pending_actions == [] and Enum.all?(Map.values(items), & &1.accepted)
    }
  end

  defp ownership_item(address, owner, pending_owner, expected_owner, action) do
    accepted =
      present?(address) and present?(owner) and present?(expected_owner) and
        normalize_address(owner) == normalize_address(expected_owner) and
        zero_or_blank_address?(pending_owner)

    status =
      cond do
        !present?(address) ->
          "unavailable"

        accepted ->
          "accepted"

        present?(expected_owner) and
            normalize_address(pending_owner) == normalize_address(expected_owner) ->
          "pending_acceptance"

        present?(owner) and present?(expected_owner) ->
          "unexpected_owner"

        true ->
          "unreadable"
      end

    %{
      owner_address: address_or_nil(owner),
      pending_owner_address: address_or_nil(pending_owner),
      accepted: accepted,
      status: status,
      action: action
    }
  end

  defp wait_blocked_reason(
         job,
         strategy,
         current_block,
         ready_with_strategy?,
         migrated?,
         migration_block_reached?,
         sweep_block_reached?
       ) do
    cond do
      job.status != "ready" ->
        "Launch job is not ready yet."

      !present?(strategy[:address]) ->
        "Strategy address is not available yet."

      !migrated? and !migration_block_reached? ->
        migration_block = strategy[:migration_block]

        if is_integer(current_block) and is_integer(migration_block) do
          "Waiting for the migration block."
        else
          "Waiting for migration to open."
        end

      migrated? and !sweep_block_reached? ->
        "Waiting for the sweep block."

      ready_with_strategy? and !migrated? and !positive_uint?(strategy[:currency_balance]) ->
        "No strategy currency is available for migration yet."

      true ->
        nil
    end
  end

  defp settled?(
         ready_with_strategy?,
         migrated?,
         sweep_block_reached?,
         sweep_actions,
         failed_auction_recoverable?,
         post_recovery_cleanup?,
         auction_asset_actions,
         strategy,
         auction
       ) do
    recovered_without_residuals? =
      ready_with_strategy? and !migrated? and !failed_auction_recoverable? and
        !post_recovery_cleanup? and sweep_block_reached? and auction_graduated?(auction) == false and
        !positive_uint?(strategy[:token_balance]) and !positive_uint?(strategy[:currency_balance]) and
        !positive_uint?(auction[:token_balance]) and !positive_uint?(auction[:currency_balance])

    (migrated? and sweep_block_reached? and sweep_actions == [] and auction_asset_actions == []) or
      recovered_without_residuals?
  end

  defp auction_graduated?(auction) do
    case auction[:graduated] do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp zero_or_blank_address?(value) do
    value in [nil, "", "0x0000000000000000000000000000000000000000"]
  end

  defp merge_launch_auction(nil, auction), do: auction

  defp merge_launch_auction(response_auction, auction) when is_map(response_auction) do
    %{
      id: map_value(response_auction, :id) || map_value(response_auction, :auction_id),
      status: map_value(response_auction, :status),
      chain_id: map_value(response_auction, :chain_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(auction || %{})
  end

  defp merge_launch_auction(_response_auction, auction), do: auction

  defp map_value(nil, _key), do: nil
  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp address_or_nil(value) when is_binary(value), do: value
  defp address_or_nil(_value), do: nil

  defp normalize_address(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_address(_value), do: nil

  defp tx_hash_param(%{"tx_hash" => <<"0x", rest::binary>> = tx_hash})
       when byte_size(rest) == 64,
       do: {:ok, String.downcase(tx_hash)}

  defp tx_hash_param(%{tx_hash: <<"0x", rest::binary>> = tx_hash}) when byte_size(rest) == 64,
    do: {:ok, String.downcase(tx_hash)}

  defp tx_hash_param(_attrs), do: {:error, :invalid_transaction_hash}
end
