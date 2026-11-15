defmodule Autolaunch.Points.Bid do
  @moduledoc """
  Regent Points' check of a bid (`autolaunch.auction_bid`): it reads the bid's
  saved position row and its auction, as the public lists carry it, and
  answers with what Points records for the account whose linked wallet placed
  the bid.

  Each Base bid is saved once as its bidder's position (`Autolaunch.Bid`), by
  whichever comes first, the bidder's page reading its receipt or the
  auction's reader, and a rebuild of the auction's activity never removes or
  changes it. One row is one bid, and in the site's own data it happened when
  the row was saved. The account that earns is the one whose verified wallets
  held the bidding wallet at that moment (`RegentPoints.WalletSnapshot.owner/2`),
  so linking, moving or removing the wallet later never changes who earned. A
  bid on an auction an operator hid, or one the lists leave out, earns
  nothing, and neither does one whose wallet no single account held then. A
  launch's creator bidding on it earns like anyone else: the catalog sets no
  rule for it.
  """

  alias Autolaunch.Actors.System
  alias RegentPoints.WalletSnapshot

  def verify(%{"source_event_key" => id}) do
    with {:ok, bid} <- saved(Autolaunch.get_bid_position(id, actor: %System{}), :bid_not_found),
         {:ok, _auction} <-
           saved(
             Autolaunch.get_listed_auction(bid.auction_id, actor: %System{}),
             :bid_not_listed
           ),
         {:ok, account_id} <- bidder(bid) do
      {:ok, facts(bid, account_id)}
    end
  end

  # A row the read does not find refuses for good; a read that failed is
  # asked again.
  defp saved({:ok, nil}, refusal), do: {:error, refusal}
  defp saved({:ok, record}, _refusal), do: {:ok, record}
  defp saved({:error, reason}, _refusal), do: {:retry, reason}

  defp bidder(bid) do
    case WalletSnapshot.owner(bid.owner_address, bid.inserted_at) do
      {:ok, account_id} -> {:ok, account_id}
      {:error, :unknown_owner} -> {:error, :bidder_wallet_not_linked}
    end
  end

  defp facts(bid, account_id) do
    %{
      source_app: Autolaunch.Points.source_app(),
      source_kind: "bid",
      source_event_key: bid.id,
      account_id: account_id,
      # The bidding wallet is the account's own; nothing saved names an agent.
      actor_kind: "human",
      actor_id: to_string(account_id),
      source_action_at: bid.inserted_at,
      qualified_at: bid.inserted_at,
      evidence_ref: "bid:" <> bid.id,
      evidence: %{
        "auction_id" => bid.auction_id,
        "onchain_bid_id" => bid.onchain_bid_id,
        "bidder" => bid.owner_address
      }
    }
  end
end
