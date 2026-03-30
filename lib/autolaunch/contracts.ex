defmodule Autolaunch.Contracts do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.Abi
  alias Autolaunch.Contracts.Dispatch
  alias Autolaunch.Launch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Revenue

  @sepolia_chain_id 11_155_111
  @zero_address "0x0000000000000000000000000000000000000000"

  def admin_overview do
    launch = launch_config()

    {:ok,
     %{
       chain_id: @sepolia_chain_id,
       dependencies: %{
         usdc_address: config_value(launch, :eth_sepolia_usdc_address),
         pool_manager_address: config_value(launch, :eth_sepolia_pool_manager_address),
         position_manager_address: config_value(launch, :eth_sepolia_position_manager_address),
         cca_factory_address: config_value(launch, :eth_sepolia_factory_address)
       },
       admin_contracts: %{
         revenue_share_factory:
           contract_admin_card(config_value(launch, :revenue_share_factory_address), [
             "set_authorized_creator"
           ]),
         revenue_ingress_factory:
           contract_admin_card(config_value(launch, :revenue_ingress_factory_address), [
             "set_authorized_creator"
           ]),
         regent_lbp_strategy_factory:
           contract_admin_card(config_value(launch, :lbp_strategy_factory_address), [])
       }
     }}
  end

  def job_state(job_id, current_human \\ nil) do
    with %{job: job} = response <- Launch.get_job_response(job_id),
         {:ok, job_scope} <- authorize_job_scope(response, current_human) do
      {:ok,
       %{
         job: job,
         scope: job_scope,
         controller: controller_card(job),
         strategy: strategy_card(job),
         vesting: vesting_card(job),
         fee_registry: fee_registry_card(job),
         fee_vault: fee_vault_card(job),
         hook: hook_card(job),
         available_actions: %{
           strategy: ~w(migrate sweep_token sweep_currency),
           vesting: ~w(release),
           fee_registry: ~w(set_hook_enabled),
           fee_vault: ~w(withdraw_treasury withdraw_regent_share set_hook)
         }
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def subject_state(subject_id, current_human \\ nil) do
    with {:ok, subject} <- Revenue.get_subject(subject_id, current_human),
         %Job{} = job <- subject_job(subject.subject_id) do
      registry = subject_registry_card(job, subject, current_human)
      splitter = splitter_card(subject)
      ingress_factory = ingress_factory_card(subject.subject_id)
      revenue_share_factory = revenue_share_factory_card()

      {:ok,
       %{
         subject: subject,
         registry: registry,
         splitter: splitter,
         ingress_factory: ingress_factory,
         revenue_share_factory: revenue_share_factory,
         available_actions: %{
           subject: ~w(stake unstake claim_usdc sweep_ingress),
           splitter:
             ~w(set_paused set_label set_treasury_recipient set_protocol_recipient set_protocol_skim_bps withdraw_treasury_residual withdraw_protocol_reserve reassign_dust),
           ingress_factory: ~w(create set_default),
           ingress_account: ~w(set_label rescue sweep),
           registry: ~w(set_subject_manager link_identity)
         }
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :subject_lookup_failed}
  end

  def prepare_job_action(job_id, resource, action, attrs, current_human \\ nil) do
    with {:ok, %{job: job, scope: _scope}} <- job_state(job_id, current_human),
         {:ok, prepared} <- Dispatch.build_job_action(job, resource, action, attrs) do
      {:ok, %{job_id: job_id, prepared: prepared}}
    end
  end

  def prepare_subject_action(subject_id, resource, action, attrs, current_human \\ nil) do
    with {:ok, %{subject: subject, registry: registry}} <-
           subject_state(subject_id, current_human),
         :ok <- authorize_subject_action(subject, registry, resource, action),
         {:ok, prepared} <-
           Dispatch.build_subject_action(subject, registry, resource, action, attrs, %{
             ingress_factory_address: ingress_factory_address()
           }) do
      {:ok, %{subject_id: subject.subject_id, prepared: prepared}}
    end
  end

  def prepare_admin_action(resource, action, attrs) do
    with {:ok, prepared} <-
           Dispatch.build_admin_action(resource, action, attrs, %{
             chain_id: @sepolia_chain_id,
             ingress_factory_address: ingress_factory_address(),
             revenue_share_factory_address: revenue_share_factory_address()
           }) do
      {:ok, %{prepared: prepared}}
    end
  end

  defp authorize_job_scope(%{job: %{owner_address: owner_address}}, %HumanUser{} = current_human) do
    wallets =
      [current_human.wallet_address | List.wrap(current_human.wallet_addresses)]
      |> Enum.map(&normalize_address/1)
      |> Enum.reject(&is_nil/1)

    if normalize_address(owner_address) in wallets do
      {:ok, %{owner_matched: true}}
    else
      {:ok, %{owner_matched: false}}
    end
  end

  defp authorize_job_scope(_response, _current_human), do: {:ok, %{owner_matched: false}}

  defp authorize_subject_action(subject, registry, resource, action) do
    allowed_direct = MapSet.new([{"ingress_account", "sweep"}])

    cond do
      MapSet.member?(allowed_direct, {resource, action}) ->
        :ok

      registry.connected_wallet_can_manage || subject.can_manage_ingress ->
        :ok

      true ->
        {:error, :forbidden}
    end
  end

  defp controller_card(job) do
    %{
      address: nil,
      deploy_binary: job.deploy_binary,
      deploy_workdir: job.deploy_workdir,
      script_target: job.script_target,
      deploy_tx_hash: job.tx_hash,
      result_addresses: %{
        auction_address: job.auction_address,
        token_address: job.token_address,
        strategy_address: job.strategy_address,
        vesting_wallet_address: job.vesting_wallet_address,
        hook_address: job.hook_address,
        launch_fee_registry_address: job.launch_fee_registry_address,
        launch_fee_vault_address: job.launch_fee_vault_address,
        subject_registry_address: job.subject_registry_address,
        subject_id: job.subject_id,
        revenue_share_splitter_address: job.revenue_share_splitter_address,
        default_ingress_address: job.default_ingress_address,
        pool_id: job.pool_id
      }
    }
  end

  defp strategy_card(job) do
    usdc = config_value(launch_config(), :eth_sepolia_usdc_address)

    %{
      address: job.strategy_address,
      token_address: safe_address_call(job.chain_id, job.strategy_address, :token),
      usdc_address: safe_address_call(job.chain_id, job.strategy_address, :usdc),
      auction_address: safe_address_call(job.chain_id, job.strategy_address, :auction_address),
      migrated: safe_bool_call(job.chain_id, job.strategy_address, :migrated),
      migration_block: safe_uint_call(job.chain_id, job.strategy_address, :migration_block),
      sweep_block: safe_uint_call(job.chain_id, job.strategy_address, :sweep_block),
      total_strategy_supply:
        safe_uint_call(job.chain_id, job.strategy_address, :total_strategy_supply),
      reserve_token_amount:
        safe_uint_call(job.chain_id, job.strategy_address, :reserve_token_amount),
      max_currency_amount_for_lp:
        safe_uint_call(job.chain_id, job.strategy_address, :max_currency_amount_for_lp),
      migrated_pool_id: safe_bytes32_call(job.chain_id, job.strategy_address, :migrated_pool_id),
      migrated_position_id:
        safe_uint_call(job.chain_id, job.strategy_address, :migrated_position_id),
      migrated_liquidity: safe_uint_call(job.chain_id, job.strategy_address, :migrated_liquidity),
      migrated_currency_for_lp:
        safe_uint_call(job.chain_id, job.strategy_address, :migrated_currency_for_lp),
      migrated_token_for_lp:
        safe_uint_call(job.chain_id, job.strategy_address, :migrated_token_for_lp),
      token_balance: safe_token_balance(job.chain_id, job.strategy_address, job.token_address),
      currency_balance: safe_token_balance(job.chain_id, job.strategy_address, usdc)
    }
  end

  defp vesting_card(job) do
    %{
      address: job.vesting_wallet_address,
      beneficiary: safe_address_call(job.chain_id, job.vesting_wallet_address, :beneficiary),
      start_timestamp: safe_uint_call(job.chain_id, job.vesting_wallet_address, :start_timestamp),
      duration_seconds:
        safe_uint_call(job.chain_id, job.vesting_wallet_address, :duration_seconds),
      released_launch_token:
        safe_uint_call(job.chain_id, job.vesting_wallet_address, :released_launch_token),
      releasable_launch_token:
        safe_uint_call(job.chain_id, job.vesting_wallet_address, :releasable_launch_token)
    }
  end

  defp fee_registry_card(job) do
    config =
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

    %{
      address: job.launch_fee_registry_address,
      pool_id: job.pool_id,
      pool_config: config
    }
  end

  defp fee_vault_card(job) do
    usdc = config_value(launch_config(), :eth_sepolia_usdc_address)

    %{
      address: job.launch_fee_vault_address,
      hook: safe_address_call(job.chain_id, job.launch_fee_vault_address, :hook),
      treasury_accrued: %{
        token:
          safe_mapping_amount(
            job.chain_id,
            job.launch_fee_vault_address,
            :treasury_accrued,
            job.pool_id,
            job.token_address
          ),
        usdc:
          safe_mapping_amount(
            job.chain_id,
            job.launch_fee_vault_address,
            :treasury_accrued,
            job.pool_id,
            usdc
          )
      },
      regent_accrued: %{
        token:
          safe_mapping_amount(
            job.chain_id,
            job.launch_fee_vault_address,
            :regent_accrued,
            job.pool_id,
            job.token_address
          ),
        usdc:
          safe_mapping_amount(
            job.chain_id,
            job.launch_fee_vault_address,
            :regent_accrued,
            job.pool_id,
            usdc
          )
      }
    }
  end

  defp hook_card(job) do
    %{
      address: job.hook_address,
      pool_id: job.pool_id
    }
  end

  defp subject_registry_card(job, subject, current_human) do
    address = job.subject_registry_address

    subject_config =
      case safe_call(
             subject.chain_id,
             address,
             Abi.encode_call(:get_subject, [{:bytes32, subject.subject_id}])
           ) do
        {:ok, data} ->
          case Abi.decode_subject_config(data) do
            {:ok, decoded} -> decoded
            _ -> nil
          end

        _ ->
          nil
      end

    wallet_address =
      case current_human do
        %HumanUser{} ->
          [current_human.wallet_address | List.wrap(current_human.wallet_addresses)]
          |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
          |> normalize_address()

        _ ->
          nil
      end

    identity_links = load_identity_links(subject.chain_id, address, subject.subject_id)

    %{
      address: address,
      owner: safe_address_call(subject.chain_id, address, :owner),
      subject_config: subject_config,
      connected_wallet_can_manage:
        if wallet_address do
          safe_bool_call(
            subject.chain_id,
            address,
            :can_manage_subject,
            [{:bytes32, subject.subject_id}, {:address, wallet_address}]
          )
        else
          false
        end,
      identity_links: identity_links
    }
  end

  defp splitter_card(subject) do
    %{
      address: subject.splitter_address,
      owner: safe_address_call(subject.chain_id, subject.splitter_address, :owner),
      label: safe_string_call(subject.chain_id, subject.splitter_address, :label),
      paused: safe_bool_call(subject.chain_id, subject.splitter_address, :paused),
      treasury_recipient:
        safe_address_call(subject.chain_id, subject.splitter_address, :treasury_recipient),
      protocol_recipient:
        safe_address_call(subject.chain_id, subject.splitter_address, :protocol_recipient),
      protocol_skim_bps:
        safe_uint_call(subject.chain_id, subject.splitter_address, :protocol_skim_bps),
      total_staked_raw: subject.total_staked_raw,
      treasury_residual_usdc_raw: subject.treasury_residual_usdc_raw,
      protocol_reserve_usdc_raw: subject.protocol_reserve_usdc_raw,
      undistributed_dust_usdc_raw: subject.undistributed_dust_usdc_raw
    }
  end

  defp ingress_factory_card(subject_id) do
    address = ingress_factory_address()

    %{
      address: address,
      owner: safe_address_call(@sepolia_chain_id, address, :owner),
      default_ingress_address:
        safe_address_call(@sepolia_chain_id, address, :default_ingress_of_subject, [
          {:bytes32, subject_id}
        ]),
      ingress_account_count:
        safe_uint_call(@sepolia_chain_id, address, :ingress_account_count, [
          {:bytes32, subject_id}
        ])
    }
  end

  defp revenue_share_factory_card do
    address = revenue_share_factory_address()

    %{
      address: address,
      owner: safe_address_call(@sepolia_chain_id, address, :owner)
    }
  end

  defp contract_admin_card(address, actions) do
    %{
      address: address,
      owner: safe_address_call(@sepolia_chain_id, address, :owner),
      actions: actions
    }
  end

  defp load_identity_links(chain_id, registry_address, subject_id) do
    count =
      safe_uint_call(chain_id, registry_address, :identity_link_count, [{:bytes32, subject_id}])

    if is_integer(count) and count > 0 do
      Enum.map(0..(count - 1), fn index ->
        case safe_call(
               chain_id,
               registry_address,
               Abi.encode_call(:identity_link_at, [{:bytes32, subject_id}, {:uint256, index}])
             ) do
          {:ok, data} ->
            case Abi.decode_identity_link(data) do
              {:ok, decoded} -> decoded
              _ -> %{index: index, error: "decode_failed"}
            end

          _ ->
            %{index: index, error: "rpc_failed"}
        end
      end)
    else
      []
    end
  end

  defp safe_mapping_amount(chain_id, to, selector_name, pool_id, currency) do
    if blank?(currency) do
      nil
    else
      safe_uint_call(chain_id, to, selector_name, [{:bytes32, pool_id}, {:address, currency}])
    end
  end

  defp safe_token_balance(chain_id, token, owner) do
    if blank?(token) or blank?(owner) do
      nil
    else
      safe_uint_call(chain_id, token, :balance_of, [{:address, owner}])
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

  defp safe_string_call(chain_id, to, selector_name, args \\ []) do
    case safe_call(chain_id, to, Abi.encode_call(selector_name, args)) do
      {:ok, data} ->
        case Abi.decode_string(data) do
          {:ok, decoded} -> decoded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_call(chain_id, to, data) do
    if blank?(to) do
      {:error, :missing_address}
    else
      Rpc.eth_call(chain_id, to, data)
    end
  end

  defp subject_job(subject_id) do
    Repo.one(
      from job in Job,
        where: job.subject_id == ^subject_id and job.status == "ready",
        order_by: [desc: job.updated_at],
        limit: 1
    )
  end

  defp normalize_address(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_address(_value), do: nil

  defp config_value(config, key) do
    config
    |> Keyword.get(key, "")
    |> normalize_address_or_text()
  end

  defp normalize_address_or_text(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, "0x") do
      String.downcase(trimmed)
    else
      trimmed
    end
  end

  defp normalize_address_or_text(value), do: value

  defp launch_config, do: Application.get_env(:autolaunch, :launch, [])

  defp ingress_factory_address,
    do: config_value(launch_config(), :revenue_ingress_factory_address)

  defp revenue_share_factory_address,
    do: config_value(launch_config(), :revenue_share_factory_address)

  defp blank?(value), do: value in [nil, "", @zero_address]
end
