defmodule Autolaunch.Launch.Jobs do
  @moduledoc false

  alias Autolaunch.Launch.Deployment
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @terminal_statuses ~w(ready failed blocked)

  def get_job_response(job_id), do: Deployment.get_job_response(job_id)

  def queue_processing(job_id) do
    case Task.Supervisor.start_child(Autolaunch.TaskSupervisor, fn -> process_job(job_id) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def terminal_status?(status), do: status in @terminal_statuses

  def process_job(job_id) do
    case Repo.get(Job, job_id) do
      nil ->
        :ok

      %Job{} = job ->
        job
        |> mark_running()
        |> run_and_persist()
    end
  rescue
    error ->
      mark_failed_after_crash(job_id, error)
  end

  defp mark_running(%Job{} = job) do
    {:ok, job} =
      job
      |> Job.update_changeset(%{
        status: "running",
        step: "deploying",
        started_at: DateTime.utc_now()
      })
      |> Repo.update()

    job
  end

  defp run_and_persist(%Job{} = job) do
    case Deployment.run_launch(job) do
      {:ok, result} ->
        auction = Deployment.persist_auction(job, result)
        mark_ready(job, result)
        mark_external_succeeded(job, auction, result)

      {:error, reason, logs} ->
        mark_failed(job, reason, logs)
        Deployment.mark_external_launch(job.job_id, "failed", %{completed_at: DateTime.utc_now()})
    end
  end

  defp mark_ready(%Job{} = job, result) do
    {:ok, _updated_job} =
      job
      |> Job.update_changeset(%{
        status: "ready",
        step: "ready",
        finished_at: DateTime.utc_now(),
        auction_address: result.auction_address,
        token_address: result.token_address,
        strategy_address: result.strategy_address,
        vesting_wallet_address: result.vesting_wallet_address,
        hook_address: result.hook_address,
        launch_fee_registry_address: result.launch_fee_registry_address,
        launch_fee_vault_address: result.launch_fee_vault_address,
        subject_registry_address: result.subject_registry_address,
        subject_id: result.subject_id,
        revenue_share_splitter_address: result.revenue_share_splitter_address,
        default_ingress_address: result.default_ingress_address,
        pool_id: result.pool_id,
        tx_hash: result.tx_hash,
        uniswap_url: result.uniswap_url,
        stdout_tail: result.stdout_tail,
        stderr_tail: result.stderr_tail
      })
      |> Repo.update()

    :ok
  end

  defp mark_failed(%Job{} = job, reason, logs) do
    job
    |> Job.update_changeset(%{
      status: "failed",
      step: "failed",
      error_message: reason,
      finished_at: DateTime.utc_now(),
      stdout_tail: Map.get(logs, :stdout_tail, ""),
      stderr_tail: Map.get(logs, :stderr_tail, "")
    })
    |> Repo.update()

    :ok
  end

  defp mark_external_succeeded(%Job{} = job, auction, result) do
    Deployment.mark_external_launch(job.job_id, "succeeded", %{
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
        "pool_id" => result.pool_id
      },
      launch_tx_hash: result.tx_hash,
      completed_at: DateTime.utc_now()
    })
  end

  defp mark_failed_after_crash(job_id, error) do
    case Repo.get(Job, job_id) do
      %Job{} = job ->
        reason = Exception.message(error)

        job
        |> Job.update_changeset(%{
          status: "failed",
          step: "failed",
          error_message: reason,
          finished_at: DateTime.utc_now()
        })
        |> Repo.update()

      nil ->
        :ok
    end

    :ok
  end
end
