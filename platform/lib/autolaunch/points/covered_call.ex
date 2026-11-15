defmodule Autolaunch.Points.CoveredCall do
  @moduledoc """
  Regent Points' check of a covered call that changed hands
  (`autolaunch.first_covered_call`): it reads the saved sale row and answers
  with what Points records for one side of it, the seller
  (`covered_call_seller`) or the buyer (`covered_call_buyer`).

  Each sale is saved once by the covered-calls reader
  (`Autolaunch.CoveredCalls.Sales`) and never changed, and it is offered once
  for each side. Each side earns for the account whose verified wallets held
  that side's wallet at the sale's block time
  (`RegentPoints.WalletSnapshot.owner/2`). The rule earns once per account, so
  an account that sells and buys, or is on both sides of one sale, earns it
  once. A listing or bid nobody bought from or sold into was never saved, and
  a side whose wallet no single account held then earns nothing.
  """

  alias Autolaunch.Actors.System
  alias RegentPoints.WalletSnapshot

  @sides %{
    "covered_call_seller" => {:seller, :seller_wallet_not_linked},
    "covered_call_buyer" => {:buyer, :buyer_wallet_not_linked}
  }

  def verify(%{"source_kind" => kind, "source_event_key" => id})
      when is_map_key(@sides, kind) do
    {side, unlinked} = Map.fetch!(@sides, kind)

    with {:ok, sale} <-
           saved(Autolaunch.CoveredCalls.get_covered_call_sale(id, actor: %System{})),
         {:ok, account_id} <- owner(Map.fetch!(sale, side), sale.occurred_at, unlinked) do
      {:ok, facts(kind, sale, account_id)}
    end
  end

  # A row the read does not find refuses for good; a read that failed is
  # asked again.
  defp saved({:ok, nil}), do: {:error, :covered_call_not_found}
  defp saved({:ok, sale}), do: {:ok, sale}
  defp saved({:error, reason}), do: {:retry, reason}

  defp owner(wallet, at, unlinked) do
    case WalletSnapshot.owner(wallet, at) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, :unknown_owner} -> {:error, unlinked}
    end
  end

  defp facts(kind, sale, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: kind,
      source_event_key: sale.id,
      account_id: account_id,
      # The side's wallet is the account's own; nothing saved names an agent.
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: sale.occurred_at,
      qualified_at: sale.occurred_at,
      evidence_ref: kind <> ":" <> sale.id,
      evidence: %{
        "chain_id" => sale.chain_id,
        "contract" => sale.contract,
        "stock" => sale.stock,
        "event" => Atom.to_string(sale.event),
        "listing_id" => sale.listing_id,
        "bid_id" => sale.bid_id,
        "seller" => sale.seller,
        "buyer" => sale.buyer,
        "amount" => Decimal.to_string(sale.amount),
        "premium" => Decimal.to_string(sale.premium),
        "fee" => Decimal.to_string(sale.fee),
        "transaction_hash" => sale.transaction_hash,
        "log_index" => sale.log_index
      }
    }
  end
end
