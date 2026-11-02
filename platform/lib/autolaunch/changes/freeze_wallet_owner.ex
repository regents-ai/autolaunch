defmodule Autolaunch.Changes.FreezeWalletOwner do
  @moduledoc """
  Saves, with a chain row, the person a wallet belonged to when the chain says
  it acted: `human_account_id`, and `pairing_id` when the wallet was that
  person's paired agent. A person's own wallet is read from the shared wallet
  history (`RegentPoints.WalletSnapshot.owner/2`); an agent's from its pairing
  then (`RegentAgents.pairing_at/2`). A wallet no one, or more than one, held
  at that moment saves no owner, and nothing is read from who holds it now.

  Options: `wallet` and `at`, the row's attributes holding the lowercase wallet
  and the event's time.
  """

  use Ash.Resource.Change

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  @impl true
  def change(changeset, opts, _context) do
    wallet = Ash.Changeset.get_attribute(changeset, opts[:wallet])
    at = Ash.Changeset.get_attribute(changeset, opts[:at])

    case owner(wallet, at) do
      {:ok, owner} -> Ash.Changeset.force_change_attributes(changeset, owner)
      {:error, reason} -> Ash.Changeset.add_error(changeset, reason)
    end
  end

  defp owner(wallet, at) do
    with {:error, :unknown_owner} <- person(wallet, at),
         {:error, :unknown_owner} <- agent(wallet, at),
         do: {:ok, %{human_account_id: nil, pairing_id: nil}}
  end

  defp person(wallet, at) do
    with {:ok, account_id} <- RegentPoints.WalletSnapshot.owner(wallet, at),
         do: {:ok, %{human_account_id: account_id, pairing_id: nil}}
  end

  defp agent(wallet, at) do
    with {:ok, pairing} <- RegentAgents.pairing_at(wallet, at) do
      case Accounts.get_by_privy_did(pairing.privy_user_id, actor: %System{}) do
        {:ok, %{id: account_id}} -> {:ok, %{human_account_id: account_id, pairing_id: pairing.id}}
        {:ok, nil} -> {:error, :unknown_owner}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
