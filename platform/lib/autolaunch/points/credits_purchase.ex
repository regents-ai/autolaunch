defmodule Autolaunch.Points.CreditsPurchase do
  @moduledoc """
  Regent Points' check of a Credits purchase in USDC: it reads the saved
  purchase and answers with what Points records. Only a credited purchase
  counts, for the account whose sign-in owns it.
  """

  require Ash.Query

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  def verify(%{"source_kind" => "credits_purchase", "source_event_key" => id}) do
    query = Ash.Query.filter(RegentCredits.Purchase, id == ^id)

    # No person is asking: Points' server check reads the committed purchase it was given.
    case RegentCredits.purchases!(query: query, authorize?: false) do
      [%{status: :credited} = purchase] -> with_account(purchase)
      [] -> {:error, :purchase_not_found}
      [_purchase] -> {:error, :purchase_not_credited}
    end
  end

  defp with_account(purchase) do
    case Accounts.get_by_privy_did(purchase.privy_user_id, actor: %System{}) do
      {:ok, %{} = account} -> {:ok, facts(purchase, account)}
      {:ok, nil} -> {:error, :purchase_account_not_found}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp facts(purchase, account) do
    %{
      # The same source as Autolaunch.Points.Award: Credits is one Regents ledger on every site.
      source_app: "regents",
      source_kind: "credits_purchase",
      source_event_key: purchase.id,
      account_id: account.id,
      actor_kind: "human",
      actor_id: to_string(account.id),
      source_action_at: purchase.inserted_at,
      qualified_at: purchase.credited_at,
      evidence_ref: "credits_purchase:" <> purchase.id,
      evidence: %{
        "purchased_usdc_atomic" => RegentCredits.Chains.micro(purchase.amount),
        "chain" => to_string(purchase.chain),
        "tx_hash" => purchase.tx_hash
      }
    }
  end
end
