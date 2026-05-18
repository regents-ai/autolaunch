defmodule Autolaunch.Launch.DeployResult do
  @moduledoc false

  alias Ecto.Multi

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.External.TokenLaunch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @default_auction_duration_seconds 259_200

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
  end

  def mark_external_launch(job_id, status, attrs) do
    update_external_launch(job_id, status, attrs)
  end

  defp update_external_launch(job_id, status, attrs) do
    case Repo.get_by(TokenLaunch, launch_job_id: job_id) do
      %TokenLaunch{} = launch ->
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

      nil ->
        {:error, :external_launch_not_found}
    end
  rescue
    error in Postgrex.Error ->
      if undefined_table?(error) do
        {:error, :external_launch_table_missing}
      else
        reraise error, __STACKTRACE__
      end
  end

  def persist_success(%Job{} = job, result) do
    now = DateTime.utc_now()
    auction_attrs = auction_attrs(job, result, now)

    Multi.new()
    |> Multi.insert(
      :auction,
      Auction.changeset(%Auction{}, auction_attrs),
      conflict_target: [:network, :auction_address],
      on_conflict: [set: Keyword.drop(Map.to_list(auction_attrs), [:source_job_id])],
      returning: true
    )
    |> Multi.update(:job, Job.update_changeset(job, ready_attrs(result, now)))
    |> Multi.run(:external_launch, fn _repo, %{auction: auction} ->
      mark_external_launch(job.job_id, "succeeded", %{
        auction_address: auction.auction_address,
        token_address: auction.token_address,
        metadata: %{
          "strategy_address" => result.strategy_address,
          "vesting_wallet_address" => result.vesting_wallet_address,
          "hook_address" => result.hook_address,
          "launch_fee_registry_address" => result.launch_fee_registry_address,
          "launch_fee_vault_address" => result.launch_fee_vault_address,
          "subject_registry_address" => result.subject_registry_address,
          "subject_id" => result.subject_id,
          "revenue_share_splitter_address" => result.revenue_share_splitter_address,
          "default_ingress_address" => result.default_ingress_address,
          "pool_id" => result.pool_id,
          "auction_quote_token_address" => result.auction_quote_token_address,
          "auction_quote_token_symbol" => result.auction_quote_token_symbol,
          "auction_quote_token_decimals" => result.auction_quote_token_decimals,
          "revenue_usdc_token_address" => result.revenue_usdc_token_address,
          "revenue_usdc_token_symbol" => result.revenue_usdc_token_symbol,
          "revenue_usdc_token_decimals" => result.revenue_usdc_token_decimals
        },
        launch_tx_hash: result.tx_hash,
        completed_at: now
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{auction: auction, job: job}} -> {:ok, %{auction: auction, job: job}}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  def persist_failure(%Job{} = job, reason, logs) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.update(:job, Job.update_changeset(job, failed_attrs(reason, logs, now)))
    |> Multi.run(:external_launch, fn _repo, _changes ->
      mark_external_launch(job.job_id, "failed", %{completed_at: now})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} -> {:ok, job}
      {:error, step, reason, _changes} -> {:error, {step, reason}}
    end
  end

  defp auction_attrs(%Job{} = job, result, now) do
    %{
      source_job_id: "auc_" <> String.replace_prefix(job.job_id, "job_", ""),
      agent_id: job.agent_id,
      agent_name: job.agent_name || job.agent_id,
      ens_name: job.ens_name,
      owner_address: job.owner_address,
      auction_address: result.auction_address,
      token_address: result.token_address,
      minimum_raise_quote: job.minimum_raise_quote,
      minimum_raise_quote_raw: job.minimum_raise_quote_raw,
      auction_quote_token_address: job.auction_quote_token_address,
      auction_quote_token_symbol: job.auction_quote_token_symbol,
      auction_quote_token_decimals: job.auction_quote_token_decimals,
      revenue_usdc_token_address: job.revenue_usdc_token_address,
      revenue_usdc_token_symbol: job.revenue_usdc_token_symbol,
      revenue_usdc_token_decimals: job.revenue_usdc_token_decimals,
      network: job.network,
      chain_id: job.chain_id,
      status: "active",
      started_at: now,
      ends_at: DateTime.add(now, @default_auction_duration_seconds, :second),
      bidders: 0,
      raised_currency: "0 REGENT",
      target_currency: "Not published",
      progress_percent: 0,
      metrics_updated_at: now,
      chain_state: "open",
      onchain_required_currency_raised_raw: job.minimum_raise_quote_raw,
      onchain_graduated: false,
      notes: job.token_symbol || job.launch_notes,
      uniswap_url: result.uniswap_url,
      world_network: job.world_network || "world",
      world_registered: job.world_registered,
      world_human_id: job.world_human_id
    }
  end

  defp ready_attrs(result, now) do
    %{
      status: "ready",
      step: "ready",
      locked_at: nil,
      locked_by: nil,
      last_heartbeat_at: now,
      finished_at: now,
      auction_address: result.auction_address,
      token_address: result.token_address,
      strategy_address: result.strategy_address,
      vesting_wallet_address: result.vesting_wallet_address,
      hook_address: result.hook_address,
      launch_fee_registry_address: result.launch_fee_registry_address,
      launch_fee_vault_address: result.launch_fee_vault_address,
      auction_quote_token_address: result.auction_quote_token_address,
      auction_quote_token_symbol: result.auction_quote_token_symbol,
      auction_quote_token_decimals: result.auction_quote_token_decimals,
      revenue_usdc_token_address: result.revenue_usdc_token_address,
      revenue_usdc_token_symbol: result.revenue_usdc_token_symbol,
      revenue_usdc_token_decimals: result.revenue_usdc_token_decimals,
      subject_registry_address: result.subject_registry_address,
      subject_id: result.subject_id,
      revenue_share_splitter_address: result.revenue_share_splitter_address,
      default_ingress_address: result.default_ingress_address,
      pool_id: result.pool_id,
      tx_hash: result.tx_hash,
      uniswap_url: result.uniswap_url,
      stdout_tail: result.stdout_tail,
      stderr_tail: result.stderr_tail
    }
  end

  defp failed_attrs(reason, logs, now) do
    %{
      status: "failed",
      step: "failed",
      locked_at: nil,
      locked_by: nil,
      last_heartbeat_at: now,
      error_message: reason,
      finished_at: now,
      stdout_tail: Map.get(logs, :stdout_tail, ""),
      stderr_tail: Map.get(logs, :stderr_tail, "")
    }
  end

  defp undefined_table?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true
  defp undefined_table?(_error), do: false
end
