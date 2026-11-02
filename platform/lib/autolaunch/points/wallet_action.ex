defmodule Autolaunch.Points.WalletAction do
  @moduledoc """
  Regent Points' check of something a wallet did on the chain: it reads the
  saved chain row and answers for the person the wallet belonged to when it
  acted, as that row froze it (`Autolaunch.Changes.FreezeWalletOwner`). A
  confirmed bid counts for `autolaunch.auction_bid`; a bid's first confirmed
  withdraw or claim for `autolaunch.first_settled_auction`; a stake in a
  launch's splitter for `autolaunch.token_staked`. A wallet that was the
  person's paired agent acts as that agent.
  """

  alias Autolaunch.Actors.System

  def verify(%{"source_kind" => "bid", "source_event_key" => key}) do
    [auction_id, bid_id] = String.split(key, ":", parts: 2)

    case Autolaunch.auction_bid(auction_id, bid_id, actor: %System{}) do
      {:ok, %{human_account_id: id} = bid} when is_integer(id) ->
        {:ok, facts(bid, bid.bidder, "bid", key)}

      {:ok, %{}} ->
        {:error, :wallet_without_owner}

      # The watcher saves a re-read stretch again in the transaction that cleared
      # it, so a missing bid is one the chain no longer holds.
      {:ok, nil} ->
        {:error, :bid_not_found}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  def verify(%{"source_kind" => "settlement", "source_event_key" => key}) do
    [auction_id, bid_id, kind] = String.split(key, ":")

    case Autolaunch.bid_settlements(auction_id, bid_id, actor: %System{}) do
      {:ok, settlements} -> settled(Enum.find(settlements, &(to_string(&1.kind) == kind)), key)
      {:error, reason} -> {:retry, reason}
    end
  end

  def verify(%{"source_kind" => "stake", "source_event_key" => key}) do
    [token_id, hash, index] = String.split(key, ":")

    case Autolaunch.token_stake(token_id, hash, String.to_integer(index), actor: %System{}) do
      {:ok, %{human_account_id: id} = stake} when is_integer(id) ->
        {:ok, facts(stake, stake.staker, "stake", key)}

      {:ok, %{}} ->
        {:error, :wallet_without_owner}

      # The watcher saves a re-read stretch again in the transaction that cleared
      # it, so a missing stake is one the chain no longer holds.
      {:ok, nil} ->
        {:error, :stake_not_found}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp settled(%{human_account_id: id} = settlement, key) when is_integer(id),
    do: {:ok, facts(settlement, settlement.owner, "settlement", key)}

  defp settled(%{}, _key), do: {:error, :wallet_without_owner}
  defp settled(nil, _key), do: {:error, :settlement_not_found}

  defp facts(row, wallet, kind, key) do
    %{
      source_app: "autolaunch",
      source_kind: kind,
      source_event_key: key,
      account_id: row.human_account_id,
      source_action_at: row.occurred_at,
      qualified_at: row.occurred_at,
      evidence_ref: kind <> ":" <> row.transaction_hash
    }
    |> Map.merge(actor(row, wallet))
  end

  defp actor(%{pairing_id: nil} = row, wallet) do
    %{
      actor_kind: "human",
      actor_id: to_string(row.human_account_id),
      evidence: %{"wallet" => wallet, "transaction_hash" => row.transaction_hash}
    }
  end

  defp actor(row, wallet) do
    %{
      actor_kind: "agent",
      # The agent's wallet, so the Points page names the agent the person paired.
      actor_id: wallet,
      evidence: %{
        "attribution_link_id" => row.pairing_id,
        "transaction_hash" => row.transaction_hash
      }
    }
  end
end
