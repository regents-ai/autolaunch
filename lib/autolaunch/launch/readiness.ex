defmodule Autolaunch.Launch.Readiness do
  @moduledoc false

  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch.Readiness.Policy

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

    policy_args = %{
      owner_address: owner_address,
      agent_id: agent_id,
      lifecycle_run_id: lifecycle_run_id
    }

    case Policy.fetch(policy_args) do
      {:ok, policy} ->
        owner_authorized =
          InfrastructureConfig.launch_value(:allow_unverified_owner) or
            Map.get(policy, :owner_authorized, false)

        prior_success = Map.get(policy, :prior_successful_launch, false)
        lifecycle_completed = Map.get(policy, :lifecycle_completed, false)
        healthy_agent = Map.get(policy, :healthy_agent_within_24h, false)
        x_verified = Map.get(policy, :x_verified, false)
        stake_lock_id = Map.get(policy, :active_stake_lock_id)

        resolved_lifecycle_run_id =
          Map.get(policy, :resolved_lifecycle_run_id) || lifecycle_run_id

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
            passed: lifecycle_completed,
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
            passed: not is_nil(stake_lock_id),
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
          resolved_lifecycle_run_id: resolved_lifecycle_run_id,
          stake_lock_id: stake_lock_id,
          blocking_status_code: if(ready_to_launch, do: nil, else: blocking.status_code),
          blocking_status_message: if(ready_to_launch, do: nil, else: blocking.status_message),
          checks: checks
        }

      {:error, _reason} ->
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
