defmodule Autolaunch.Launch.Deployment do
  @moduledoc false

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.External.TokenLaunch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @default_auction_duration_seconds 259_200
  @chain_configs %{
    84_532 => %{
      id: 84_532,
      key: "base-sepolia",
      family: "base",
      label: "Base Sepolia",
      short_label: "Base Sepolia",
      uniswap_network: "base_sepolia",
      testnet?: true
    },
    8_453 => %{
      id: 8_453,
      key: "base-mainnet",
      family: "base",
      label: "Base",
      short_label: "Base",
      uniswap_network: "base",
      testnet?: false
    }
  }
  @supported_chain_ids [84_532, 8_453]

  def get_job_response(job_id) do
    with {:ok, active_chain_id} <- launch_chain_id() do
      case Repo.get(Job, job_id) do
        nil ->
          {:error, :not_found}

        %Job{chain_id: ^active_chain_id} = job ->
          {:ok,
           %{
             job: Autolaunch.Launch.Core.serialize_job(job),
             auction: maybe_load_job_auction(job)
           }}

        %Job{} ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :job_lookup_failed}
    Postgrex.Error -> {:error, :job_lookup_failed}
  end

  def record_external_launch(%Job{} = job) do
    now = DateTime.utc_now()
    launch_id = "atl_" <> Ecto.UUID.generate()

    attrs = %{
      launch_id: launch_id,
      owner_address: job.owner_address,
      agent_id: job.agent_id,
      lifecycle_run_id: job.lifecycle_run_id,
      chain_id: job.chain_id,
      total_supply: job.total_supply,
      vesting_beneficiary: job.agent_safe_address,
      beneficiary_confirmed_at: now,
      vesting_start_at: now,
      vesting_end_at: DateTime.add(now, 365 * 24 * 60 * 60, :second),
      launch_status: "queued",
      launch_job_id: job.job_id,
      metadata: %{
        "source" => "autolaunch",
        "token_name" => job.token_name,
        "token_symbol" => job.token_symbol
      }
    }

    %TokenLaunch{}
    |> TokenLaunch.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [launch_status: "queued", updated_at: now]],
      conflict_target: :launch_job_id
    )
  rescue
    _ -> :ok
  end

  def mark_external_launch(job_id, status, attrs) do
    if launch = Repo.get_by(TokenLaunch, launch_job_id: job_id) do
      attrs =
        case Map.get(attrs, :metadata) do
          metadata when is_map(metadata) ->
            Map.put(attrs, :metadata, Map.merge(launch.metadata || %{}, metadata))

          _ ->
            attrs
        end

      launch
      |> TokenLaunch.changeset(Map.put(attrs, :launch_status, status))
      |> Repo.update()
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def persist_auction(%Job{} = job, result) do
    now = DateTime.utc_now()

    attrs = %{
      source_job_id: "auc_" <> String.replace_prefix(job.job_id, "job_", ""),
      agent_id: job.agent_id,
      agent_name: job.agent_name || job.agent_id,
      ens_name: job.ens_name,
      owner_address: job.owner_address,
      auction_address: result.auction_address,
      token_address: result.token_address,
      minimum_raise_usdc: job.minimum_raise_usdc,
      minimum_raise_usdc_raw: job.minimum_raise_usdc_raw,
      network: job.network,
      chain_id: job.chain_id,
      status: "active",
      started_at: now,
      ends_at: DateTime.add(now, @default_auction_duration_seconds, :second),
      bidders: 0,
      raised_currency: "0 USDC",
      target_currency: "Not published",
      progress_percent: 0,
      metrics_updated_at: now,
      notes: job.token_symbol || job.launch_notes,
      uniswap_url: result.uniswap_url,
      world_network: job.world_network || "world",
      world_registered: job.world_registered,
      world_human_id: job.world_human_id
    }

    {:ok, auction} =
      Repo.insert(
        Auction.changeset(%Auction{}, attrs),
        conflict_target: [:network, :auction_address],
        on_conflict: [set: Keyword.drop(Map.to_list(attrs), [:source_job_id])],
        returning: true
      )

    auction
  end

  def run_launch(%Job{} = job) do
    if mock_deploy?(), do: simulate_launch(job), else: run_command_launch(job)
  end

  def deploy_binary do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:deploy_binary, "forge")
  end

  def deploy_workdir do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:deploy_workdir, "")
  end

  def deploy_script_target do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:deploy_script_target, "")
  end

  def deploy_rpc_host(chain_id) do
    case deploy_rpc_url(chain_id) do
      nil ->
        nil

      "" ->
        nil

      url ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) -> host
          _ -> "custom"
        end
    end
  end

  defp maybe_load_job_auction(%Job{auction_address: address, network: network})
       when is_binary(address) and address != "" do
    Autolaunch.Launch.AuctionDetails.get_auction_by_address(network, address, nil)
  end

  defp maybe_load_job_auction(_job), do: nil

  defp simulate_launch(job) do
    :timer.sleep(1_200)

    suffix =
      Ecto.UUID.generate()
      |> String.replace("-", "")
      |> String.slice(0, 40)

    auction_address = "0x" <> suffix
    token_address = "0x" <> String.reverse(suffix)
    strategy_address = "0x" <> String.duplicate("a", 40)
    vesting_wallet_address = "0x" <> String.duplicate("9", 40)
    hook_address = "0x" <> String.duplicate("b", 40)
    launch_fee_registry_address = "0x" <> String.duplicate("c", 40)
    launch_fee_vault_address = "0x" <> String.duplicate("e", 40)
    subject_registry_address = "0x" <> String.duplicate("d", 40)
    subject_id = "0x" <> String.duplicate("1", 64)
    revenue_share_splitter_address = "0x" <> String.duplicate("6", 40)
    default_ingress_address = "0x" <> String.duplicate("7", 40)
    pool_id = "0x" <> String.duplicate("f", 64)

    {:ok,
     %{
       auction_address: auction_address,
       token_address: token_address,
       strategy_address: strategy_address,
       vesting_wallet_address: vesting_wallet_address,
       hook_address: hook_address,
       launch_fee_registry_address: launch_fee_registry_address,
       launch_fee_vault_address: launch_fee_vault_address,
       subject_registry_address: subject_registry_address,
       subject_id: subject_id,
       revenue_share_splitter_address: revenue_share_splitter_address,
       default_ingress_address: default_ingress_address,
       pool_id: pool_id,
       tx_hash: "0x" <> String.duplicate("a", 64),
       uniswap_url: to_uniswap_url(job.chain_id, token_address),
       stdout_tail:
         "CCA_RESULT_JSON:{\"factoryAddress\":\"#{deploy_factory_address(job.chain_id)}\",\"auctionAddress\":\"#{auction_address}\",\"tokenAddress\":\"#{token_address}\",\"strategyAddress\":\"#{strategy_address}\",\"vestingWalletAddress\":\"#{vesting_wallet_address}\",\"hookAddress\":\"#{hook_address}\",\"launchFeeRegistryAddress\":\"#{launch_fee_registry_address}\",\"feeVaultAddress\":\"#{launch_fee_vault_address}\",\"subjectRegistryAddress\":\"#{subject_registry_address}\",\"subjectId\":\"#{subject_id}\",\"revenueShareSplitterAddress\":\"#{revenue_share_splitter_address}\",\"defaultIngressAddress\":\"#{default_ingress_address}\",\"poolId\":\"#{pool_id}\"}",
       stderr_tail: ""
     }}
  end

  defp run_command_launch(job) do
    binary = deploy_binary()
    workdir = deploy_workdir()
    script_target = deploy_script_target()
    rpc_url = deploy_rpc_url(job.chain_id)
    deploy_error = deploy_env_error(job.chain_id)

    cond do
      blank?(rpc_url) ->
        {:error, "Missing deploy RPC URL for #{job.network}.",
         %{stdout_tail: "", stderr_tail: ""}}

      deploy_error ->
        {:error, deploy_error, %{stdout_tail: "", stderr_tail: ""}}

      true ->
        args =
          ["script", script_target, "--rpc-url", rpc_url] ++
            credentials_args() ++ broadcast_args(job)

        task =
          Task.async(fn ->
            command_runner().cmd(binary, args,
              cd: workdir,
              env: command_env(job),
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, deploy_timeout_ms()) do
          {:ok, {output, 0}} ->
            parse_launch_output(job, output)

          {:ok, {output, exit_code}} ->
            {:error, "Forge exited with status #{exit_code}.",
             %{stdout_tail: trim_tail(output), stderr_tail: ""}}

          nil ->
            Task.shutdown(task, :brutal_kill)

            {:error, "Forge timed out while waiting for deployment.",
             %{stdout_tail: "", stderr_tail: ""}}
        end
    end
  rescue
    error ->
      {:error, Exception.message(error), %{stdout_tail: "", stderr_tail: ""}}
  end

  defp parse_launch_output(job, output) do
    marker = deploy_output_marker()

    with {:ok, parsed} <- parse_launch_output_payload(output, marker),
         {:ok, auction_address} <- required_launch_output_address(parsed, "auctionAddress"),
         {:ok, token_address} <- required_launch_output_address(parsed, "tokenAddress"),
         {:ok, strategy_address} <- required_launch_output_address(parsed, "strategyAddress"),
         {:ok, vesting_wallet_address} <-
           required_launch_output_address(parsed, "vestingWalletAddress"),
         {:ok, hook_address} <- required_launch_output_address(parsed, "hookAddress"),
         {:ok, launch_fee_registry_address} <-
           required_launch_output_address(parsed, "launchFeeRegistryAddress"),
         {:ok, launch_fee_vault_address} <-
           required_launch_output_address(parsed, "feeVaultAddress"),
         {:ok, subject_registry_address} <-
           required_launch_output_address(parsed, "subjectRegistryAddress"),
         {:ok, subject_id} <- required_launch_output_hex(parsed, "subjectId", 64),
         {:ok, revenue_share_splitter_address} <-
           required_launch_output_address(parsed, "revenueShareSplitterAddress"),
         {:ok, default_ingress_address} <-
           required_launch_output_address(parsed, "defaultIngressAddress"),
         {:ok, pool_id} <- required_launch_output_hex(parsed, "poolId", 64) do
      {:ok,
       %{
         auction_address: auction_address,
         token_address: token_address,
         strategy_address: strategy_address,
         vesting_wallet_address: vesting_wallet_address,
         hook_address: hook_address,
         launch_fee_registry_address: launch_fee_registry_address,
         launch_fee_vault_address: launch_fee_vault_address,
         subject_registry_address: subject_registry_address,
         subject_id: subject_id,
         revenue_share_splitter_address: revenue_share_splitter_address,
         default_ingress_address: default_ingress_address,
         pool_id: pool_id,
         tx_hash: Map.get(parsed, "txHash"),
         uniswap_url: to_uniswap_url(job.chain_id, token_address),
         stdout_tail: trim_tail(output),
         stderr_tail: ""
       }}
    else
      {:error, message} ->
        {:error, message, %{stdout_tail: trim_tail(output), stderr_tail: ""}}
    end
  end

  defp parse_launch_output_payload(output, marker) do
    case latest_marked_json(output, marker) do
      nil -> {:error, "Deployment output missing deterministic marker #{marker}."}
      parsed -> {:ok, parsed}
    end
  end

  defp latest_marked_json(output, marker) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(nil, fn line, latest ->
      case String.split(line, marker, parts: 2) do
        [_prefix, suffix] ->
          case Jason.decode(String.trim(suffix)) do
            {:ok, parsed} -> parsed
            _ -> latest
          end

        _ ->
          latest
      end
    end)
  end

  defp deploy_output_marker do
    Application.get_env(:autolaunch, :launch, [])
    |> Keyword.get(:deploy_output_marker, "CCA_RESULT_JSON:")
  end

  defp deploy_timeout_ms do
    launch_config()
    |> Keyword.get(:deploy_timeout_ms, 180_000)
    |> normalize_timeout_ms()
  end

  defp command_runner do
    launch_config()
    |> Keyword.get(:command_runner_module, System)
  end

  defp deploy_rpc_url(chain_id), do: config_value_for_chain(chain_id, :rpc_url)

  defp mock_deploy? do
    launch_config()
    |> Keyword.get(:mock_deploy, false)
  end

  defp credentials_args do
    config = launch_config()
    account = Keyword.get(config, :deploy_account, "")
    password = Keyword.get(config, :deploy_password, "")
    private_key = Keyword.get(config, :deploy_private_key, "")

    cond do
      account != "" and password != "" -> ["--account", account, "--password", password]
      account != "" -> ["--account", account]
      private_key != "" -> ["--private-key", private_key]
      true -> []
    end
  end

  defp broadcast_args(%Job{broadcast: true}), do: ["--broadcast"]
  defp broadcast_args(_job), do: []

  defp command_env(job) do
    [
      {"AUTOLAUNCH_OWNER_ADDRESS", job.owner_address},
      {"AUTOLAUNCH_AGENT_ID", job.agent_id},
      {"AUTOLAUNCH_AGENT_NAME", job.agent_name || ""},
      {"AUTOLAUNCH_TOKEN_NAME", job.token_name || ""},
      {"AUTOLAUNCH_TOKEN_SYMBOL", job.token_symbol || ""},
      {"CCA_REQUIRED_CURRENCY_RAISED", job.minimum_raise_usdc_raw || "0"},
      {"AUTOLAUNCH_TOTAL_SUPPLY", job.total_supply},
      {"AUTOLAUNCH_AGENT_SAFE_ADDRESS", job.agent_safe_address || ""},
      {"AUTOLAUNCH_LIFECYCLE_RUN_ID", job.lifecycle_run_id || ""},
      {"AUTOLAUNCH_LAUNCH_NOTES", job.launch_notes || ""},
      {"AUTOLAUNCH_NETWORK", job.network},
      {"AUTOLAUNCH_CHAIN_ID", Integer.to_string(job.chain_id)},
      {"AUTOLAUNCH_REVENUE_SHARE_FACTORY_ADDRESS", deploy_revenue_share_factory_address()},
      {"AUTOLAUNCH_REVENUE_INGRESS_FACTORY_ADDRESS", deploy_revenue_ingress_factory_address()},
      {"AUTOLAUNCH_LBP_STRATEGY_FACTORY_ADDRESS", deploy_lbp_strategy_factory_address()},
      {"AUTOLAUNCH_TOKEN_FACTORY_ADDRESS", deploy_token_factory_address()},
      {"REGENT_MULTISIG_ADDRESS", deploy_regent_multisig_address()},
      {"AUTOLAUNCH_USDC_ADDRESS", deploy_usdc_address(job.chain_id)},
      {"AUTOLAUNCH_CCA_FACTORY_ADDRESS", deploy_factory_address(job.chain_id)},
      {"AUTOLAUNCH_UNISWAP_V4_POOL_MANAGER", deploy_pool_manager_address(job.chain_id)},
      {"AUTOLAUNCH_UNISWAP_V4_POSITION_MANAGER", deploy_position_manager_address(job.chain_id)}
    ]
  end

  defp to_uniswap_url(chain_id, token_address) do
    case chain_config(chain_id) do
      %{uniswap_network: network} when is_binary(network) and is_binary(token_address) ->
        "https://app.uniswap.org/explore/tokens/#{network}/#{token_address}"

      _ ->
        nil
    end
  end

  defp normalize_address(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.downcase(trimmed)
  end

  defp normalize_address(_value), do: nil

  defp required_launch_output_address(parsed, key) do
    case normalize_address(Map.get(parsed, key)) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Deployment output did not include #{key}."}
    end
  end

  defp required_launch_output_hex(parsed, key, bytes) do
    case Map.get(parsed, key) do
      "0x" <> value = hex when byte_size(value) == bytes -> {:ok, String.downcase(hex)}
      _ -> {:error, "Deployment output did not include #{key}."}
    end
  end

  defp trim_tail(output) when is_binary(output) do
    String.slice(output, max(String.length(output) - 20_000, 0), 20_000)
  end

  defp trim_tail(_output), do: ""

  defp normalize_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value), do: 180_000

  defp launch_config do
    Application.get_env(:autolaunch, :launch, [])
  end

  defp fetch_chain_config(chain_id) do
    case chain_config(chain_id) do
      nil -> {:error, :invalid_chain_id}
      config -> {:ok, config}
    end
  end

  defp chain_config(chain_id), do: Map.get(@chain_configs, chain_id)

  defp deploy_factory_address(chain_id),
    do: config_value_for_chain(chain_id, :cca_factory_address)

  defp deploy_pool_manager_address(chain_id),
    do: config_value_for_chain(chain_id, :pool_manager_address)

  defp deploy_regent_multisig_address do
    Keyword.get(
      launch_config(),
      :regent_multisig_address,
      "0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e"
    )
  end

  defp deploy_revenue_share_factory_address,
    do: Keyword.get(launch_config(), :revenue_share_factory_address, "")

  defp deploy_revenue_ingress_factory_address,
    do: Keyword.get(launch_config(), :revenue_ingress_factory_address, "")

  defp deploy_lbp_strategy_factory_address,
    do: Keyword.get(launch_config(), :lbp_strategy_factory_address, "")

  defp deploy_token_factory_address,
    do: Keyword.get(launch_config(), :token_factory_address, "")

  defp deploy_position_manager_address(chain_id),
    do: config_value_for_chain(chain_id, :position_manager_address)

  defp deploy_usdc_address(chain_id), do: config_value_for_chain(chain_id, :usdc_address)

  defp deploy_env_error(chain_id) do
    with {:ok, chain} <- fetch_chain_config(chain_id) do
      cond do
        blank?(deploy_script_target()) ->
          "Missing launch deploy script target."

        blank?(deploy_workdir()) ->
          "Missing launch deploy workdir."

        blank?(deploy_revenue_share_factory_address()) ->
          "Missing revenue share factory address."

        blank?(deploy_revenue_ingress_factory_address()) ->
          "Missing revenue ingress factory address."

        blank?(deploy_lbp_strategy_factory_address()) ->
          "Missing Regent LBP strategy factory address."

        blank?(deploy_token_factory_address()) ->
          "Missing token factory address."

        blank?(deploy_pool_manager_address(chain_id)) ->
          "Missing #{chain.label} Uniswap v4 pool manager address."

        blank?(deploy_factory_address(chain_id)) ->
          "Missing #{chain.label} CCA factory address."

        blank?(deploy_usdc_address(chain_id)) ->
          "Missing #{chain.label} USDC address."

        true ->
          nil
      end
    else
      _ -> "Unsupported deploy network."
    end
  end

  defp config_value_for_chain(chain_id, key) do
    with {:ok, active_chain_id} <- launch_chain_id(),
         true <- chain_id == active_chain_id do
      Keyword.get(launch_config(), key, "")
    else
      _ -> ""
    end
  end

  defp launch_chain_id do
    normalize_chain_id(Keyword.get(launch_config(), :chain_id, 84_532))
  end

  defp normalize_chain_id(value) when is_integer(value) do
    if value in @supported_chain_ids, do: {:ok, value}, else: {:error, :invalid_chain_id}
  end

  defp normalize_chain_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_chain_id(parsed)
      _ -> {:error, :invalid_chain_id}
    end
  end

  defp normalize_chain_id(_value), do: {:error, :invalid_chain_id}

  defp blank?(value), do: value in [nil, ""]
end
