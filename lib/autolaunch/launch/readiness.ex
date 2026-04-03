defmodule Autolaunch.Launch.Readiness do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Launch.External.IronspriteAgent
  alias Autolaunch.Launch.External.LifecycleRun
  alias Autolaunch.Launch.External.RegentbotAgent
  alias Autolaunch.Launch.External.SocialAccount
  alias Autolaunch.Launch.External.TokenLaunch
  alias Autolaunch.Launch.External.TokenLaunchStake
  alias Autolaunch.Repo

  @blocking_check_keys ~w(
    ownerAuthorized
    noPriorSuccessfulLaunch
    lifecycleCompleted
    healthyAgentWithin24h
    stakeLockActive
    beneficiaryAddressValid
    beneficiaryConfirmed
  )

  @type result :: %{
          ready_to_launch: boolean(),
          resolved_lifecycle_run_id: String.t() | nil,
          stake_lock_id: String.t() | nil,
          blocking_status_code: integer() | nil,
          blocking_status_message: String.t() | nil,
          checks: [map()]
        }

  def collect(args) do
    owner_address = normalize_address(Map.fetch!(args, :owner_address))
    agent_id = Map.fetch!(args, :agent_id)
    lifecycle_run_id = normalize_optional_text(Map.get(args, :lifecycle_run_id), 64)
    vesting_beneficiary = normalize_address(Map.get(args, :vesting_beneficiary))
    beneficiary_confirmed = Map.get(args, :beneficiary_confirmed) == true

    try do
      now = DateTime.utc_now()
      health_cutoff = DateTime.add(now, -(24 * 60 * 60), :second)

      regentbot_match =
        Repo.exists?(
          from agent in RegentbotAgent,
            where: agent.owner_address == ^owner_address and agent.agent_id == ^agent_id
        )

      ironsprite_match =
        Repo.exists?(
          from agent in IronspriteAgent,
            where: agent.owner_address == ^owner_address and agent.agent_id == ^agent_id
        )

      prior_success =
        Repo.exists?(
          from launch in TokenLaunch,
            where: launch.owner_address == ^owner_address and launch.launch_status == "succeeded"
        )

      lifecycle_run_query =
        from run in LifecycleRun,
          where:
            run.owner_address == ^owner_address and run.agent_id == ^agent_id and
              run.state == "completed",
          order_by: [desc: run.updated_at],
          limit: 1

      lifecycle_run_query =
        if lifecycle_run_id do
          from run in lifecycle_run_query, where: run.run_id == ^lifecycle_run_id
        else
          lifecycle_run_query
        end

      lifecycle_run = Repo.one(lifecycle_run_query)

      healthy_agent =
        Repo.exists?(
          from agent in IronspriteAgent,
            where:
              agent.owner_address == ^owner_address and agent.agent_id == ^agent_id and
                agent.status == "active" and not is_nil(agent.last_health_check_at) and
                agent.last_health_check_at >= ^health_cutoff
        )

      x_verified =
        Repo.exists?(
          from account in SocialAccount,
            where:
              account.owner_address == ^owner_address and account.agent_id == ^agent_id and
                account.provider == "x" and account.status == "verified" and
                not is_nil(account.verified_at)
        )

      active_stake =
        Repo.one(
          from stake in TokenLaunchStake,
            where:
              stake.owner_address == ^owner_address and stake.status == "active" and
                stake.unlock_at >= ^now,
            order_by: [desc: stake.unlock_at],
            limit: 1
        )

      owner_authorized =
        Keyword.get(Application.get_env(:autolaunch, :launch, []), :allow_unverified_owner, false) or
          regentbot_match or ironsprite_match

      checks = [
        %{
          key: "ownerAuthorized",
          passed: owner_authorized,
          message: "Owner must control this agent in Regentbot or Ironsprite."
        },
        %{
          key: "noPriorSuccessfulLaunch",
          passed: not prior_success,
          message: "Only one successful CCA launch is allowed per owner."
        },
        %{
          key: "lifecycleCompleted",
          passed: not is_nil(lifecycle_run),
          message: "A completed lifecycle run is required for this agent."
        },
        %{
          key: "healthyAgentWithin24h",
          passed: healthy_agent,
          message: "Agent health must be green within the last 24 hours."
        },
        %{
          key: "xVerified",
          passed: x_verified,
          message: "An X account can be attached later as an optional public trust signal."
        },
        %{
          key: "stakeLockActive",
          passed: not is_nil(active_stake),
          message: "An active REGENT stake lock is required before launch."
        },
        %{
          key: "beneficiaryAddressValid",
          passed: valid_hex_address?(vesting_beneficiary),
          message: "Provide a valid vesting beneficiary address."
        },
        %{
          key: "beneficiaryConfirmed",
          passed: beneficiary_confirmed,
          message: "Explicitly confirm the beneficiary before queueing launch."
        }
      ]

      ready_to_launch =
        Enum.all?(checks, fn check ->
          check.passed or check.key not in @blocking_check_keys
        end)

      blocking = blocking_error(checks)

      %{
        ready_to_launch: ready_to_launch,
        resolved_lifecycle_run_id: lifecycle_run && lifecycle_run.run_id,
        stake_lock_id: active_stake && active_stake.lock_id,
        blocking_status_code: if(ready_to_launch, do: nil, else: blocking.status_code),
        blocking_status_message: if(ready_to_launch, do: nil, else: blocking.status_message),
        checks: checks
      }
    rescue
      Ecto.QueryError ->
        degraded_result(agent_id, lifecycle_run_id, vesting_beneficiary, beneficiary_confirmed)

      Postgrex.Error ->
        degraded_result(agent_id, lifecycle_run_id, vesting_beneficiary, beneficiary_confirmed)

      DBConnection.ConnectionError ->
        degraded_result(agent_id, lifecycle_run_id, vesting_beneficiary, beneficiary_confirmed)
    end
  end

  def passed_count(%{checks: checks}) do
    Enum.count(checks, & &1.passed)
  end

  defp degraded_result(agent_id, lifecycle_run_id, vesting_beneficiary, beneficiary_confirmed) do
    checks = [
      %{
        key: "ownerAuthorized",
        passed: false,
        message: "Shared Regent launch-policy tables are unavailable for this environment."
      },
      %{
        key: "noPriorSuccessfulLaunch",
        passed: false,
        message: "Shared Regent launch-policy tables are unavailable for this environment."
      },
      %{
        key: "lifecycleCompleted",
        passed: lifecycle_run_id not in [nil, ""],
        message:
          "Lifecycle completion can only be confirmed when the shared policy tables are present."
      },
      %{
        key: "healthyAgentWithin24h",
        passed: false,
        message: "Agent health can only be confirmed when the shared policy tables are present."
      },
      %{
        key: "xVerified",
        passed: false,
        message: "X verification is optional public trust metadata and cannot be confirmed here."
      },
      %{
        key: "stakeLockActive",
        passed: false,
        message: "Stake lock can only be confirmed when the shared policy tables are present."
      },
      %{
        key: "beneficiaryAddressValid",
        passed: valid_hex_address?(vesting_beneficiary),
        message: "Provide a valid vesting beneficiary address."
      },
      %{
        key: "beneficiaryConfirmed",
        passed: beneficiary_confirmed,
        message: "Explicitly confirm the beneficiary before queueing launch."
      }
    ]

    %{
      ready_to_launch: false,
      resolved_lifecycle_run_id: lifecycle_run_id || "manual:#{agent_id}",
      stake_lock_id: nil,
      blocking_status_code: 503,
      blocking_status_message: "Shared launch-policy tables are unavailable.",
      checks: checks
    }
  end

  defp blocking_error(checks) do
    failed = checks |> Enum.reject(& &1.passed) |> Map.new(&{&1.key, &1})

    cond do
      Map.has_key?(failed, "ownerAuthorized") ->
        %{status_code: 403, status_message: "Owner address is not authorized for this agent."}

      Map.has_key?(failed, "noPriorSuccessfulLaunch") ->
        %{status_code: 409, status_message: "Owner already has a successful CCA launch."}

      Map.has_key?(failed, "lifecycleCompleted") ->
        %{status_code: 412, status_message: "A completed lifecycle run is required."}

      Map.has_key?(failed, "healthyAgentWithin24h") ->
        %{status_code: 412, status_message: "Agent health must be green within 24 hours."}

      Map.has_key?(failed, "stakeLockActive") ->
        %{status_code: 423, status_message: "An active REGENT stake lock is required."}

      Map.has_key?(failed, "beneficiaryConfirmed") ->
        %{status_code: 400, status_message: "Beneficiary confirmation is required."}

      Map.has_key?(failed, "beneficiaryAddressValid") ->
        %{status_code: 400, status_message: "Beneficiary address is invalid."}

      true ->
        %{status_code: 400, status_message: "Launch request is blocked."}
    end
  end

  defp valid_hex_address?(value) do
    is_binary(value) and Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, value)
  end

  defp normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_address(_value), do: nil

  defp normalize_optional_text(value, max_length) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp normalize_optional_text(_value, _max_length), do: nil
end
