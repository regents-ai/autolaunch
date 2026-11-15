defmodule Autolaunch.Points.Trade do
  @moduledoc """
  Regent Points' check of a trade (`autolaunch.token_traded`): it reads the
  saved trade by the pool log it came from, and the token, as the public lists
  carry it, and answers with what Points records for the account whose linked
  wallet made the trade.

  Each trade is saved from its `Swap` log by the token's reader
  (`Autolaunch.TokenTrades`), with the wallet that sent its transaction. The
  pool's own log names only the router that called it, so the sender is the
  trader. A trade happened at its block's time, and the account that earns is
  the one whose verified wallets held the trading wallet at that moment
  (`RegentPoints.WalletSnapshot.owner/2`). A trade in a token an operator hid
  or the lists leave out earns nothing, and neither does one saved before the
  site recorded traders, nor one whose wallet no single account held then.

  A trade is offered only when it is first saved, so one saved while this
  rule is not approved is never offered later, unless a rebuild of the
  token's trades after the chain changed saves it again; a rebuild also asks
  the node again for the sender of every trade in the token's history, one
  lookup per transaction, four at a time.
  """

  alias Autolaunch.Actors.System
  alias RegentPoints.WalletSnapshot

  @doc "The key a trade is offered to Points under: its token and pool log."
  def key(%{token_id: token_id, transaction_hash: hash, log_index: index}),
    do: "#{token_id}:#{hash}:#{index}"

  def verify(%{"source_event_key" => key}) do
    with {:ok, trade} <- saved(trade(key), :trade_not_found),
         {:ok, _token} <-
           saved(
             Autolaunch.get_listed_token(trade.token_id, actor: %System{}),
             :trade_not_listed
           ),
         {:ok, account_id} <- trader(trade) do
      {:ok, facts(key, trade, account_id)}
    end
  end

  defp trade(key) do
    with [token_id, hash, index] <- String.split(key, ":"),
         {index, ""} <- Integer.parse(index) do
      Autolaunch.get_token_trade(token_id, hash, index, actor: %System{})
    else
      _ -> {:ok, nil}
    end
  end

  # A row the read does not find refuses for good; a read that failed is
  # asked again.
  defp saved({:ok, nil}, refusal), do: {:error, refusal}
  defp saved({:ok, record}, _refusal), do: {:ok, record}
  defp saved({:error, reason}, _refusal), do: {:retry, reason}

  defp trader(%{trader: nil}), do: {:error, :trader_unknown}

  defp trader(trade) do
    case WalletSnapshot.owner(trade.trader, trade.occurred_at) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, :unknown_owner} -> {:error, :trader_wallet_not_linked}
    end
  end

  defp facts(key, trade, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "trade",
      source_event_key: key,
      account_id: account_id,
      # The trading wallet is the account's own; nothing saved names an agent.
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: trade.occurred_at,
      qualified_at: trade.occurred_at,
      evidence_ref: "trade:" <> key,
      evidence: %{
        "token_id" => trade.token_id,
        "transaction_hash" => trade.transaction_hash,
        "log_index" => trade.log_index,
        "side" => Atom.to_string(trade.side),
        "trader" => trade.trader
      }
    }
  end
end
