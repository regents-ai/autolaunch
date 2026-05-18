defmodule Autolaunch.Launch.Deployment do
  @moduledoc false

  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch.AuctionDetails
  alias Autolaunch.Launch.DeployCommand
  alias Autolaunch.Launch.DeployOutput
  alias Autolaunch.Launch.DeployResult
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

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

  def record_external_launch(%Job{} = job), do: DeployResult.record_external_launch(job)

  def mark_external_launch(job_id, status, attrs),
    do: DeployResult.mark_external_launch(job_id, status, attrs)

  def persist_auction(%Job{} = job, result) do
    case DeployResult.persist_success(job, result) do
      {:ok, %{auction: auction}} -> auction
      {:error, reason} -> raise "failed to persist launch result: #{inspect(reason)}"
    end
  end

  def run_launch(%Job{} = job) do
    if mock_deploy?(), do: simulate_launch(job), else: run_command_launch(job)
  end

  def deploy_binary, do: DeployCommand.deploy_binary(launch_config())
  def deploy_workdir, do: DeployCommand.deploy_workdir(launch_config())
  def deploy_script_target, do: DeployCommand.deploy_script_target(launch_config())
  def deploy_rpc_host(chain_id), do: DeployCommand.deploy_rpc_host(chain_id, launch_config())

  defp maybe_load_job_auction(%Job{auction_address: address, network: network})
       when is_binary(address) and address != "" do
    AuctionDetails.get_auction_by_address(network, address, nil)
  end

  defp maybe_load_job_auction(_job), do: nil

  defp simulate_launch(job) do
    :timer.sleep(1_200)

    suffix =
      (Ecto.UUID.generate() <> Ecto.UUID.generate())
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
    auction_quote_token = InfrastructureConfig.auction_quote_token(job.chain_id)
    revenue_usdc_token = InfrastructureConfig.revenue_usdc_token(job.chain_id)

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
       auction_quote_token_address: auction_quote_token.address,
       auction_quote_token_symbol: auction_quote_token.symbol,
       auction_quote_token_decimals: auction_quote_token.decimals,
       revenue_usdc_token_address: revenue_usdc_token.address,
       revenue_usdc_token_symbol: revenue_usdc_token.symbol,
       revenue_usdc_token_decimals: revenue_usdc_token.decimals,
       tx_hash: "0x" <> String.duplicate("a", 64),
       uniswap_url: DeployOutput.to_uniswap_url(job.chain_id, token_address),
       stdout_tail:
         "#{deploy_output_marker()}{\"factoryAddress\":\"#{deploy_factory_address(job.chain_id)}\",\"auctionAddress\":\"#{auction_address}\",\"tokenAddress\":\"#{token_address}\",\"strategyAddress\":\"#{strategy_address}\",\"vestingWalletAddress\":\"#{vesting_wallet_address}\",\"hookAddress\":\"#{hook_address}\",\"launchFeeRegistryAddress\":\"#{launch_fee_registry_address}\",\"feeVaultAddress\":\"#{launch_fee_vault_address}\",\"subjectRegistryAddress\":\"#{subject_registry_address}\",\"subjectId\":\"#{subject_id}\",\"revenueShareSplitterAddress\":\"#{revenue_share_splitter_address}\",\"defaultIngressAddress\":\"#{default_ingress_address}\",\"poolId\":\"#{pool_id}\",\"auctionQuoteTokenAddress\":\"#{auction_quote_token.address}\",\"auctionQuoteSymbol\":\"#{auction_quote_token.symbol}\",\"auctionQuoteDecimals\":#{auction_quote_token.decimals},\"revenueUsdcTokenAddress\":\"#{revenue_usdc_token.address}\",\"revenueSymbol\":\"#{revenue_usdc_token.symbol}\",\"revenueDecimals\":#{revenue_usdc_token.decimals}}",
       stderr_tail: ""
     }}
  end

  defp run_command_launch(%Job{} = job) do
    with {:ok, command} <- DeployCommand.build(job, launch_config()) do
      run_command_with_timeout(fn ->
        command_runner().cmd(command.binary, command.args, command.opts)
      end)
      |> case do
        {:ok, {output, 0}} ->
          DeployOutput.parse(job, output, deploy_output_marker())

        {:ok, {output, exit_code}} ->
          {:error, "Forge exited with status #{exit_code}.",
           %{stdout_tail: DeployOutput.trim_tail(output), stderr_tail: ""}}

        :timeout ->
          {:error, "Forge timed out while waiting for deployment.",
           %{stdout_tail: "", stderr_tail: ""}}
      end
    end
  rescue
    error ->
      {:error, Exception.message(error), %{stdout_tail: "", stderr_tail: ""}}
  end

  defp run_command_with_timeout(fun) do
    task =
      Task.Supervisor.async_nolink(Autolaunch.TaskSupervisor, fn ->
        fun.()
      end)

    case Task.yield(task, deploy_timeout_ms()) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  defp deploy_output_marker do
    launch_config()
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

  defp mock_deploy? do
    launch_config()
    |> Keyword.get(:mock_deploy, false)
  end

  defp deploy_factory_address(chain_id),
    do: DeployCommand.config_value_for_chain(chain_id, :cca_factory_address, launch_config())

  defp launch_config do
    InfrastructureConfig.launch()
  end

  defp launch_chain_id do
    InfrastructureConfig.launch_chain_id()
  end

  defp normalize_timeout_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout_ms(_value), do: 180_000
end
