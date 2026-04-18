defmodule Autolaunch.ReleaseDeployVerifier do
  @moduledoc false

  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.Abi
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @zero_address "0x0000000000000000000000000000000000000000"
  @launch_stack_deployed_topic0 "0x0f4620e4f0d6524b6aca672f72348ff2535a365b816545538f83084e8d073077"

  def run(job_id, opts \\ []) when is_binary(job_id) do
    case Repo.get(Job, job_id) do
      %Job{} = job ->
        controller_resolution = resolve_controller(job, opts)

        checks =
          [
            job_ready_check(job),
            controller_resolution.check
          ] ++
            controller_checks(job, controller_resolution.address) ++
            [
              accepted_owner_check(
                "fee_registry_ownership",
                job.chain_id,
                job.launch_fee_registry_address,
                job.agent_safe_address,
                "Fee registry ownership is fully accepted by the Agent Safe."
              ),
              accepted_owner_check(
                "fee_vault_ownership",
                job.chain_id,
                job.launch_fee_vault_address,
                job.agent_safe_address,
                "Fee vault ownership is fully accepted by the Agent Safe."
              ),
              accepted_owner_check(
                "hook_ownership",
                job.chain_id,
                job.hook_address,
                job.agent_safe_address,
                "Fee hook ownership is fully accepted by the Agent Safe."
              ),
              fee_vault_canonical_tokens_check(job),
              strategy_migration_check(job),
              pool_and_position_recorded_check(job),
              fee_hook_pool_wiring_check(job),
              fee_vault_hook_check(job),
              subject_registry_wiring_check(job),
              ingress_wiring_check(job)
            ]

        %{
          ok: Enum.all?(checks, &blocking_check_ok?/1),
          job_id: job.job_id,
          controller_address: controller_resolution.address,
          checks: checks
        }

      nil ->
        %{
          ok: false,
          job_id: job_id,
          controller_address: nil,
          checks: [
            fail_check(
              "job_lookup",
              :error,
              "Launch job #{job_id} was not found."
            )
          ]
        }
    end
  end

  defp job_ready_check(%Job{status: "ready"}) do
    ok_check("job_ready", :error, "Launch job is present and marked ready.")
  end

  defp job_ready_check(%Job{status: status}) do
    fail_check("job_ready", :error, "Launch job is not ready yet. Current status: #{status}.")
  end

  defp controller_checks(_job, nil), do: []

  defp controller_checks(job, controller_address) do
    [
      controller_owner_check(job.chain_id, controller_address),
      authorized_creator_revoked_check(
        "revenue_share_factory_controller_auth",
        job.chain_id,
        revenue_share_factory_address(),
        controller_address,
        "Revenue share factory no longer authorizes the deployment controller."
      ),
      authorized_creator_revoked_check(
        "revenue_ingress_factory_controller_auth",
        job.chain_id,
        revenue_ingress_factory_address(),
        controller_address,
        "Revenue ingress factory no longer authorizes the deployment controller."
      )
    ]
  end

  defp resolve_controller(job, opts) do
    supplied =
      opts
      |> Keyword.get(:controller_address)
      |> normalize_address()

    cond do
      configured_address?(supplied) ->
        %{
          address: supplied,
          check:
            ok_check(
              "controller_address",
              :error,
              "Using supplied controller address #{supplied}."
            )
        }

      configured_tx_hash?(job.tx_hash) ->
        case controller_from_receipt(job.chain_id, job.tx_hash) do
          {:ok, controller} ->
            %{
              address: controller,
              check:
                ok_check(
                  "controller_address",
                  :error,
                  "Recovered controller address #{controller} from the deploy transaction."
                )
            }

          {:error, reason} ->
            %{
              address: nil,
              check:
                fail_check(
                  "controller_address",
                  :warning,
                  "Could not recover the controller address from the deploy transaction: #{reason}. Pass --controller-address to run controller-specific checks."
                )
            }
        end

      true ->
        %{
          address: nil,
          check:
            fail_check(
              "controller_address",
              :warning,
              "Launch job has no deploy transaction hash. Pass --controller-address to run controller-specific checks."
            )
        }
    end
  end

  defp controller_from_receipt(chain_id, tx_hash) do
    with {:ok, %{logs: logs}} <- Rpc.tx_receipt(chain_id, tx_hash),
         %{} = log <-
           Enum.find(logs, fn log ->
             is_list(log.topics) and log.topics != [] and
               Enum.at(log.topics, 0) == @launch_stack_deployed_topic0
           end) do
      case normalize_address(log.address) do
        controller ->
          if configured_address?(controller) do
            {:ok, controller}
          else
            {:error, "event address was missing or invalid"}
          end
      end
    else
      {:ok, nil} -> {:error, "receipt not found yet"}
      {:error, reason} -> {:error, inspect(reason)}
      nil -> {:error, "LaunchStackDeployed event was not found in the receipt"}
    end
  end

  defp controller_owner_check(chain_id, controller_address) do
    case safe_address_call(chain_id, controller_address, :owner) do
      owner ->
        if configured_address?(owner) do
          ok_check(
            "controller_owner",
            :error,
            "Controller owner is #{owner}."
          )
        else
          fail_check(
            "controller_owner",
            :error,
            "Controller owner could not be read from #{controller_address}."
          )
        end
    end
  end

  defp fee_hook_pool_wiring_check(job) do
    expected_hook = normalize_address(job.hook_address)
    expected_quote_token = config_value(launch_config(), :usdc_address)
    expected_pool_manager = config_value(launch_config(), :pool_manager_address)

    case pool_config(job) do
      %{hook_enabled: true, hook: hook, quote_token: quote_token, pool_manager: pool_manager} ->
        if normalize_address(hook) == expected_hook and
             normalize_address(quote_token) == normalize_address(expected_quote_token) and
             normalize_address(pool_manager) == normalize_address(expected_pool_manager) do
          ok_check(
            "fee_hook_pool_wiring",
            :error,
            "Pool config points at the expected fixed fee hook, pool manager, and quote token."
          )
        else
          fail_check(
            "fee_hook_pool_wiring",
            :error,
            "Pool config is present but does not match the expected hook wiring."
          )
        end

      %{hook_enabled: false} ->
        fail_check("fee_hook_pool_wiring", :error, "Fee hook is disabled in the pool config.")

      _ ->
        fail_check(
          "fee_hook_pool_wiring",
          :error,
          "Pool config could not be read from the fee registry."
        )
    end
  end

  defp authorized_creator_revoked_check(
         key,
         chain_id,
         factory_address,
         controller_address,
         detail
       ) do
    case safe_bool_call(chain_id, factory_address, :authorized_creators, [
           {:address, controller_address}
         ]) do
      false ->
        ok_check(key, :error, detail)

      true ->
        fail_check(
          key,
          :error,
          "Deployment controller #{controller_address} is still authorized in #{factory_address}."
        )

      _ ->
        fail_check(
          key,
          :error,
          "Could not read authorized creator status from #{factory_address}."
        )
    end
  end

  defp accepted_owner_check(key, chain_id, contract_address, expected_owner, ok_detail) do
    owner = safe_address_call(chain_id, contract_address, :owner)
    pending_owner = safe_address_call(chain_id, contract_address, :pending_owner)

    cond do
      normalize_address(owner) != normalize_address(expected_owner) ->
        fail_check(
          key,
          :error,
          "Owner on #{contract_address} is #{owner || "unreadable"}, expected #{expected_owner}."
        )

      pending_owner != @zero_address ->
        fail_check(
          key,
          :error,
          "Pending owner on #{contract_address} is still #{pending_owner || "unreadable"}."
        )

      true ->
        ok_check(key, :error, ok_detail)
    end
  end

  defp fee_vault_canonical_tokens_check(job) do
    launch_token =
      safe_address_call(job.chain_id, job.launch_fee_vault_address, :canonical_launch_token)

    quote_token =
      safe_address_call(job.chain_id, job.launch_fee_vault_address, :canonical_quote_token)

    expected_quote_token = config_value(launch_config(), :usdc_address)

    cond do
      normalize_address(launch_token) != normalize_address(job.token_address) ->
        fail_check(
          "fee_vault_canonical_tokens",
          :error,
          "Fee vault launch token is #{launch_token || "unreadable"}, expected #{job.token_address}."
        )

      normalize_address(quote_token) != normalize_address(expected_quote_token) ->
        fail_check(
          "fee_vault_canonical_tokens",
          :error,
          "Fee vault quote token is #{quote_token || "unreadable"}, expected #{expected_quote_token}."
        )

      true ->
        ok_check(
          "fee_vault_canonical_tokens",
          :error,
          "Fee vault canonical launch and quote tokens match the launch stack."
        )
    end
  end

  defp strategy_migration_check(job) do
    case safe_bool_call(job.chain_id, job.strategy_address, :migrated) do
      true ->
        ok_check("strategy_migrated", :error, "Strategy migration is complete.")

      false ->
        fail_check("strategy_migrated", :error, "Strategy migration has not completed yet.")

      _ ->
        fail_check("strategy_migrated", :error, "Strategy migration state could not be read.")
    end
  end

  defp pool_and_position_recorded_check(job) do
    migrated_pool_id = safe_bytes32_call(job.chain_id, job.strategy_address, :migrated_pool_id)

    migrated_position_id =
      safe_uint_call(job.chain_id, job.strategy_address, :migrated_position_id)

    migrated_liquidity = safe_uint_call(job.chain_id, job.strategy_address, :migrated_liquidity)

    cond do
      migrated_pool_id != job.pool_id ->
        fail_check(
          "strategy_pool_and_position",
          :error,
          "Strategy recorded pool id #{migrated_pool_id || "unreadable"}, expected #{job.pool_id}."
        )

      not is_integer(migrated_position_id) or migrated_position_id <= 0 ->
        fail_check(
          "strategy_pool_and_position",
          :error,
          "Strategy did not record a usable Uniswap position id."
        )

      not is_integer(migrated_liquidity) or migrated_liquidity <= 0 ->
        fail_check(
          "strategy_pool_and_position",
          :error,
          "Strategy did not record positive migrated liquidity."
        )

      true ->
        ok_check(
          "strategy_pool_and_position",
          :error,
          "Strategy recorded the expected pool id, position id, and liquidity."
        )
    end
  end

  defp fee_vault_hook_check(job) do
    case safe_address_call(job.chain_id, job.launch_fee_vault_address, :hook) do
      hook ->
        if normalize_address(hook) == normalize_address(job.hook_address) do
          ok_check("fee_vault_hook", :error, "Fee vault points at the expected hook contract.")
        else
          fail_check(
            "fee_vault_hook",
            :error,
            "Fee vault hook is #{hook || "unreadable"}, expected #{job.hook_address}."
          )
        end
    end
  end

  defp subject_registry_wiring_check(job) do
    case subject_config(job) do
      %{
        stake_token: stake_token,
        splitter: splitter,
        treasury_safe: treasury_safe,
        active: true
      } ->
        if normalize_address(stake_token) == normalize_address(job.token_address) and
             normalize_address(splitter) == normalize_address(job.revenue_share_splitter_address) and
             normalize_address(treasury_safe) == normalize_address(job.agent_safe_address) do
          case pool_config(job) do
            %{treasury: treasury} ->
              if normalize_address(treasury) ==
                   normalize_address(job.revenue_share_splitter_address) do
                ok_check(
                  "subject_registry_wiring",
                  :error,
                  "Subject registry and fee registry both point at the expected splitter."
                )
              else
                fail_check(
                  "subject_registry_wiring",
                  :error,
                  "Fee registry treasury does not point at the expected splitter."
                )
              end

            _ ->
              fail_check(
                "subject_registry_wiring",
                :error,
                "Fee registry treasury does not point at the expected splitter."
              )
          end
        else
          fail_check(
            "subject_registry_wiring",
            :error,
            "Subject registry wiring does not match the recorded token, splitter, Agent Safe, or active state."
          )
        end

      %{} ->
        fail_check(
          "subject_registry_wiring",
          :error,
          "Subject registry wiring does not match the recorded token, splitter, Agent Safe, or active state."
        )

      _ ->
        fail_check(
          "subject_registry_wiring",
          :error,
          "Subject config could not be read from the subject registry."
        )
    end
  end

  defp ingress_wiring_check(job) do
    ingress_factory = revenue_ingress_factory_address()

    case safe_address_call(job.chain_id, ingress_factory, :default_ingress_of_subject, [
           {:bytes32, job.subject_id}
         ]) do
      ingress ->
        if normalize_address(ingress) == normalize_address(job.default_ingress_address) do
          ok_check(
            "ingress_wiring",
            :error,
            "Default ingress matches the recorded launch output."
          )
        else
          fail_check(
            "ingress_wiring",
            :error,
            "Default ingress is #{ingress || "unreadable"}, expected #{job.default_ingress_address}."
          )
        end
    end
  end

  defp pool_config(job) do
    case safe_call(
           job.chain_id,
           job.launch_fee_registry_address,
           Abi.encode_call(:get_pool_config, [{:bytes32, job.pool_id}])
         ) do
      {:ok, data} ->
        case Abi.decode_pool_config(data) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp subject_config(job) do
    case safe_call(
           job.chain_id,
           job.subject_registry_address,
           Abi.encode_call(:get_subject, [{:bytes32, job.subject_id}])
         ) do
      {:ok, data} ->
        case Abi.decode_subject_config(data) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_uint_call(chain_id, to, selector_name, args \\ []) do
    case safe_call(chain_id, to, Abi.encode_call(selector_name, args)) do
      {:ok, data} -> Abi.decode_uint256(data)
      _ -> nil
    end
  end

  defp safe_bool_call(chain_id, to, selector_name, args \\ []) do
    case safe_call(chain_id, to, Abi.encode_call(selector_name, args)) do
      {:ok, data} -> Abi.decode_bool(data)
      _ -> nil
    end
  end

  defp safe_address_call(chain_id, to, selector_name, args \\ []) do
    case safe_call(chain_id, to, Abi.encode_call(selector_name, args)) do
      {:ok, data} -> Abi.decode_address(data)
      _ -> nil
    end
  end

  defp safe_bytes32_call(chain_id, to, selector_name, args \\ []) do
    case safe_call(chain_id, to, Abi.encode_call(selector_name, args)) do
      {:ok, data} -> Abi.decode_bytes32(data)
      _ -> nil
    end
  end

  defp safe_call(_chain_id, to, _data) when not is_binary(to) or to == "" do
    {:error, :missing_address}
  end

  defp safe_call(chain_id, to, data) do
    Rpc.eth_call(chain_id, to, data)
  end

  defp launch_config, do: Application.get_env(:autolaunch, :launch, [])

  defp revenue_share_factory_address,
    do: config_value(launch_config(), :revenue_share_factory_address)

  defp revenue_ingress_factory_address,
    do: config_value(launch_config(), :revenue_ingress_factory_address)

  defp config_value(config, key) do
    config
    |> Keyword.get(key, "")
    |> normalize_address()
  end

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp configured_address?(value) when is_binary(value) do
    Regex.match?(~r/^0x[0-9a-f]{40}$/, value)
  end

  defp configured_address?(_value), do: false

  defp configured_tx_hash?(value) when is_binary(value) do
    Regex.match?(~r/^0x[0-9a-fA-F]{64}$/, String.trim(value))
  end

  defp configured_tx_hash?(_value), do: false

  defp blocking_check_ok?(%{severity: :warning}), do: true
  defp blocking_check_ok?(%{ok: ok}), do: ok

  defp ok_check(key, severity, detail),
    do: %{key: key, ok: true, severity: severity, detail: detail}

  defp fail_check(key, severity, detail),
    do: %{key: key, ok: false, severity: severity, detail: detail}
end
