defmodule Autolaunch.Portfolio do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Launch
  alias Autolaunch.Portfolio.RefreshJobs
  alias Autolaunch.Portfolio.Snapshot
  alias Autolaunch.Repo
  alias Autolaunch.Revenue

  @refresh_cooldown_seconds 30

  def get_snapshot(nil), do: {:error, :unauthorized}

  def get_snapshot(%HumanUser{} = human) do
    case snapshot_record(human.id) do
      nil ->
        schedule_refresh(human, :bootstrap)
        {:ok, snapshot_record(human.id) |> serialize_snapshot()}

      %Snapshot{} = snapshot ->
        if should_bootstrap?(snapshot) do
          schedule_refresh(human, :bootstrap)
        end

        {:ok, serialize_snapshot(snapshot)}
    end
  end

  def schedule_login_refresh(%HumanUser{} = human) do
    schedule_refresh(human, :login)
    :ok
  end

  def request_manual_refresh(nil), do: {:error, :unauthorized}

  def request_manual_refresh(%HumanUser{} = human) do
    now = DateTime.utc_now()
    snapshot = snapshot_record(human.id)

    if cooldown_active?(snapshot, now) do
      {:error, {:cooldown, cooldown_seconds_remaining(snapshot, now)}}
    else
      snapshot =
        snapshot
        |> ensure_snapshot(human.id)
        |> Snapshot.changeset(%{
          status: "running",
          refresh_started_at: now,
          next_manual_refresh_at: DateTime.add(now, @refresh_cooldown_seconds, :second),
          error_message: nil
        })
        |> Repo.insert_or_update!()

      schedule_refresh(human, :manual)
      {:ok, serialize_snapshot(snapshot)}
    end
  end

  def get_holdings(nil), do: {:error, :unauthorized}

  def get_holdings(%HumanUser{} = human) do
    wallets = linked_wallet_addresses(human)
    directory_rows = launch_module().list_auctions(%{"mode" => "all", "sort" => "newest"}, nil)

    items =
      directory_rows
      |> Enum.filter(&(is_binary(&1.subject_id) and &1.subject_id != ""))
      |> Enum.reduce([], fn row, acc ->
        with {:ok, %{position: position, subject: subject}} <-
               revenue_module().subject_portfolio_state(row.subject_id, wallets, human) do
          holding = %{
            holding_type: "subject",
            auction_id: row.id,
            subject_id: row.subject_id,
            agent_id: row.agent_id,
            agent_name: row.agent_name,
            symbol: row.symbol,
            token_address: subject.token_address,
            splitter_address: subject.splitter_address,
            default_ingress_address: subject.default_ingress_address,
            wallet_addresses: wallets,
            unstaked_token_balance: subject.wallet_token_balance,
            unstaked_token_balance_raw: subject.wallet_token_balance_raw,
            staked_token_balance: position.wallet_stake_balance,
            staked_token_balance_raw: position.wallet_stake_balance_raw,
            claimable_usdc: position.claimable_usdc,
            claimable_usdc_raw: position.claimable_usdc_raw,
            claimable_emissions: position_value(position, :claimable_stake_token),
            claimable_emissions_raw: position_value(position, :claimable_stake_token_raw, 0),
            ingress_accounts: subject.ingress_accounts,
            available_actions: available_holding_actions(subject, position)
          }

          if has_holding_balance?(holding), do: [holding | acc], else: acc
        else
          _ -> acc
        end
      end)
      |> Enum.reverse()

    {:ok,
     %{
       wallet_addresses: wallets,
       items: items,
       generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  def refresh_snapshot(%HumanUser{} = human) do
    snapshot = snapshot_record(human.id) |> ensure_snapshot(human.id)
    wallets = linked_wallet_addresses(human)
    directory_rows = launch_module().list_auctions(%{"mode" => "all", "sort" => "newest"}, nil)

    launched_tokens =
      directory_rows
      |> Enum.filter(&(&1.owner_address in wallets))
      |> Enum.map(&serialize_launched_token/1)

    staked_tokens =
      directory_rows
      |> Enum.filter(&(is_binary(&1.subject_id) and &1.subject_id != ""))
      |> Enum.reduce([], fn row, acc ->
        case revenue_module().subject_wallet_positions(row.subject_id, wallets) do
          {:ok, position} when position.wallet_stake_balance_raw > 0 ->
            [serialize_staked_token(row, position) | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    now = DateTime.utc_now()

    snapshot
    |> Snapshot.changeset(%{
      status: "ready",
      launched_tokens_payload: launched_tokens,
      staked_tokens_payload: staked_tokens,
      refreshed_at: now,
      refresh_started_at: now,
      error_message: nil
    })
    |> Repo.insert_or_update()
  rescue
    error ->
      snapshot_record(human.id)
      |> ensure_snapshot(human.id)
      |> Snapshot.changeset(%{
        status: "error",
        error_message: Exception.message(error),
        refresh_started_at: DateTime.utc_now()
      })
      |> Repo.insert_or_update()
  end

  defp serialize_launched_token(row) do
    %{
      auction_id: row.id,
      subject_id: row.subject_id,
      agent_id: row.agent_id,
      agent_name: row.agent_name,
      symbol: row.symbol,
      phase: row.phase,
      current_price_usdc: row.current_price_usdc,
      implied_market_cap_usdc: row.implied_market_cap_usdc,
      detail_url: row.subject_url || row.detail_url
    }
  end

  defp serialize_staked_token(row, position) do
    %{
      auction_id: row.id,
      subject_id: row.subject_id,
      agent_id: row.agent_id,
      agent_name: row.agent_name,
      symbol: row.symbol,
      phase: row.phase,
      current_price_usdc: row.current_price_usdc,
      implied_market_cap_usdc: row.implied_market_cap_usdc,
      staked_token_amount: position.wallet_stake_balance,
      staked_token_amount_raw: position.wallet_stake_balance_raw,
      staked_usdc_value:
        multiply_decimal_strings(position.wallet_stake_balance, row.current_price_usdc),
      claimable_usdc: position.claimable_usdc,
      claimable_usdc_raw: position.claimable_usdc_raw,
      claimable_emissions: position_value(position, :claimable_stake_token),
      claimable_emissions_raw: position_value(position, :claimable_stake_token_raw, 0),
      detail_url: row.subject_url || row.detail_url
    }
  end

  defp available_holding_actions(subject, position) do
    []
    |> maybe_action(position.wallet_stake_balance_raw > 0, "unstake")
    |> maybe_action(subject.wallet_token_balance_raw > 0, "stake")
    |> maybe_action(position.claimable_usdc_raw > 0, "claim_usdc")
    |> maybe_action(
      position_value(position, :claimable_stake_token_raw, 0) > 0,
      "claim_emissions"
    )
    |> maybe_action(
      position_value(position, :claimable_stake_token_raw, 0) > 0,
      "claim_and_stake_emissions"
    )
    |> maybe_action(
      subject.can_manage_ingress and
        Enum.any?(subject.ingress_accounts, &(&1.usdc_balance_raw > 0)),
      "sweep_ingress"
    )
  end

  defp maybe_action(actions, true, action), do: actions ++ [action]
  defp maybe_action(actions, _condition, _action), do: actions

  defp has_holding_balance?(holding) do
    Enum.any?(
      [
        Map.get(holding, :unstaked_token_balance_raw),
        Map.get(holding, :staked_token_balance_raw),
        Map.get(holding, :claimable_usdc_raw),
        Map.get(holding, :claimable_emissions_raw)
      ],
      &positive_integer?/1
    )
  end

  defp positive_integer?(value) when is_integer(value), do: value > 0
  defp positive_integer?(_value), do: false

  defp position_value(position, key, default \\ nil) when is_map(position) do
    Map.get(position, key, default)
  end

  defp multiply_decimal_strings(nil, _right), do: nil
  defp multiply_decimal_strings(_left, nil), do: nil

  defp multiply_decimal_strings(left, right) do
    Decimal.mult(Decimal.new(left), Decimal.new(right))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp schedule_refresh(%HumanUser{} = human, _reason) do
    now = DateTime.utc_now()

    snapshot =
      snapshot_record(human.id)
      |> ensure_snapshot(human.id)
      |> Snapshot.changeset(%{
        status: "running",
        refresh_started_at: now,
        error_message: nil
      })
      |> Repo.insert_or_update!()

    _ = RefreshJobs.start(human)

    {:ok, snapshot}
  end

  defp snapshot_record(human_id) when is_integer(human_id) do
    Repo.get_by(Snapshot, human_id: human_id)
  end

  defp ensure_snapshot(nil, human_id), do: %Snapshot{human_id: human_id}
  defp ensure_snapshot(%Snapshot{} = snapshot, _human_id), do: snapshot

  defp cooldown_active?(nil, _now), do: false

  defp cooldown_active?(%Snapshot{next_manual_refresh_at: nil}, _now), do: false

  defp cooldown_active?(%Snapshot{next_manual_refresh_at: next_at}, now) do
    DateTime.compare(next_at, now) == :gt
  end

  defp cooldown_seconds_remaining(%Snapshot{next_manual_refresh_at: nil}, _now), do: 0

  defp cooldown_seconds_remaining(%Snapshot{next_manual_refresh_at: next_at}, now) do
    next_at
    |> DateTime.diff(now, :second)
    |> max(0)
  end

  defp should_bootstrap?(%Snapshot{
         status: "running",
         refresh_started_at: %DateTime{} = started_at
       }) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) > 30
  end

  defp should_bootstrap?(%Snapshot{status: status}) when status in ["pending", "error"], do: true
  defp should_bootstrap?(_snapshot), do: false

  defp linked_wallet_addresses(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_address(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_address(_value), do: nil

  defp serialize_snapshot(nil) do
    %{
      status: "pending",
      launched_tokens: [],
      staked_tokens: [],
      refreshed_at: nil,
      refresh_started_at: nil,
      next_manual_refresh_at: nil,
      error_message: nil
    }
  end

  defp serialize_snapshot(%Snapshot{} = snapshot) do
    %{
      status: snapshot.status,
      launched_tokens: snapshot.launched_tokens_payload || [],
      staked_tokens: snapshot.staked_tokens_payload || [],
      refreshed_at: iso(snapshot.refreshed_at),
      refresh_started_at: iso(snapshot.refresh_started_at),
      next_manual_refresh_at: iso(snapshot.next_manual_refresh_at),
      error_message: snapshot.error_message
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp launch_module do
    :autolaunch
    |> Application.get_env(:portfolio, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp revenue_module do
    :autolaunch
    |> Application.get_env(:portfolio, [])
    |> Keyword.get(:revenue_module, Revenue)
  end
end
