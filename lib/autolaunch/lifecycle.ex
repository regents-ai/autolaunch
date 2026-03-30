defmodule Autolaunch.Lifecycle do
  @moduledoc false

  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts
  alias Autolaunch.Launch

  def job_summary(job_id, current_human \\ nil) do
    with %{job: job} = response <- Launch.get_job_response(job_id),
         {:ok, contract_scope} <- Contracts.job_state(job_id, current_human) do
      current_block = current_block(job.chain_id)
      strategy = contract_scope.strategy || %{}
      vesting = contract_scope.vesting || %{}
      flags = summary_flags(job, strategy, vesting, current_block)

      {:ok,
       %{
         job: response.job,
         auction: response.auction,
         strategy: strategy,
         vesting: vesting,
         current_block: current_block,
         recommended_action: recommended_action(flags)
       }}
       |> then(&Map.merge(&1, flags))
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def prepare_finalize(job_id, current_human \\ nil) do
    with {:ok, summary} <- job_summary(job_id, current_human) do
      prepared = prepare_action(job_id, summary.recommended_action, current_human)

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
         release_ready: summary.vesting_release_ready
       }}
    end
  end

  def summary_flags(job, strategy, vesting, current_block) do
    ready_with_strategy? = job_ready_with_strategy?(job, strategy)

    migrate_ready =
      ready_with_strategy? and !truthy?(strategy[:migrated]) and
        block_reached?(current_block, strategy[:migration_block])

    sweep_window_open? =
      ready_with_strategy? and block_reached?(current_block, strategy[:sweep_block])

    %{
      migrate_ready: migrate_ready,
      currency_sweep_ready: sweep_window_open? and positive_uint?(strategy[:currency_balance]),
      token_sweep_ready: sweep_window_open? and positive_uint?(strategy[:token_balance]),
      vesting_release_ready: positive_uint?(vesting[:releasable_launch_token])
    }
  end

  def recommended_action(flags) do
    cond do
      flags.migrate_ready -> "migrate"
      flags.currency_sweep_ready -> "sweep_currency"
      flags.token_sweep_ready -> "sweep_token"
      flags.vesting_release_ready -> "release_vesting"
      true -> "wait"
    end
  end

  def prepare_scope_action("migrate"), do: {:ok, {"strategy", "migrate"}}
  def prepare_scope_action("sweep_currency"), do: {:ok, {"strategy", "sweep_currency"}}
  def prepare_scope_action("sweep_token"), do: {:ok, {"strategy", "sweep_token"}}
  def prepare_scope_action("release_vesting"), do: {:ok, {"vesting", "release"}}
  def prepare_scope_action(_action), do: :noop

  defp prepare_action(job_id, action, current_human) do
    case prepare_scope_action(action) do
      {:ok, {scope, action_name}} ->
        Contracts.prepare_job_action(job_id, scope, action_name, %{}, current_human)

      :noop ->
        {:ok, %{job_id: job_id, prepared: nil}}
    end
  end

  defp job_ready_with_strategy?(job, strategy), do: job.status == "ready" and present?(strategy[:address])

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

  defp tx_hash_param(%{"tx_hash" => <<"0x", rest::binary>> = tx_hash})
       when byte_size(rest) == 64,
       do: {:ok, String.downcase(tx_hash)}

  defp tx_hash_param(%{tx_hash: <<"0x", rest::binary>> = tx_hash}) when byte_size(rest) == 64,
    do: {:ok, String.downcase(tx_hash)}

  defp tx_hash_param(_attrs), do: {:error, :invalid_transaction_hash}
end
