defmodule Autolaunch.Points.Trade do
  @moduledoc """
  Regent Points' check of a swap sent from the site's trade panel
  (`autolaunch.token_traded`): it reads the saved record, then counts the trade
  for that record's account once the site's own chain feed holds a swap from
  that transaction and the chain says the wallet saved with it sent it. A swap
  the feed has not read yet is checked again later; the record alone never
  counts.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Client

  def verify(%{"source_kind" => "trade", "source_event_key" => id}) do
    with {:ok, trade} <- site_trade(id),
         {:ok, swap} <- swap(trade),
         :ok <- sent_by(trade) do
      {:ok, facts(trade, swap)}
    end
  end

  defp site_trade(id) do
    case Autolaunch.get_site_trade(id, actor: %System{}) do
      {:ok, nil} -> {:error, :trade_not_found}
      {:ok, trade} -> {:ok, trade}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp swap(trade) do
    case Autolaunch.transaction_trades(trade.chain_id, trade.transaction_hash, actor: %System{}) do
      {:ok, [swap | _]} -> {:ok, swap}
      {:ok, []} -> {:retry, :trade_not_seen}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp sent_by(trade) do
    case Client.receipt(%{chain_id: trade.chain_id}, trade.transaction_hash) do
      {:ok, %{"from" => from}} when is_binary(from) ->
        if String.downcase(from) == trade.wallet,
          do: :ok,
          else: {:error, :trade_from_another_wallet}

      {:ok, _not_landed} ->
        {:retry, :receipt_unavailable}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp facts(trade, swap) do
    %{
      source_app: "autolaunch",
      source_kind: "trade",
      source_event_key: trade.id,
      account_id: trade.human_account_id,
      actor_kind: "human",
      actor_id: to_string(trade.human_account_id),
      source_action_at: swap.occurred_at,
      qualified_at: swap.occurred_at,
      evidence_ref: "trade:" <> trade.transaction_hash,
      evidence: %{
        "chain_id" => trade.chain_id,
        "wallet" => trade.wallet,
        "transaction_hash" => trade.transaction_hash
      }
    }
  end
end
