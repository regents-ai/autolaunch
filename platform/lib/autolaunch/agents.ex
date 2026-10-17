defmodule Autolaunch.Agents do
  @moduledoc """
  Reads the shared Regent account an agent's pairing names, without creating
  records on agent reads. A person's shared account exists on every Regent
  site from their first sign-in on any of them.
  """
  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Agent, System}

  def resolve(wallet) do
    with {:ok, pairing} <- RegentAgents.Authority.resolve(Repo, wallet),
         {:ok, %{} = account} <-
           Accounts.get_by_privy_did(pairing.privy_user_id, actor: %System{}) do
      {:ok,
       %Agent{
         wallet_address: wallet,
         privy_user_id: pairing.privy_user_id,
         pairing_id: pairing.id,
         acting_agent_id: pairing.id,
         human_account_id: account.id
       }, account}
    else
      {:ok, nil} -> {:error, :account_unavailable}
      error -> error
    end
  end

  # How a check-in (`GET /api/agents/v1/me`) names the person's account: their
  # shared account, or nil only when the Privy identity has no shared account
  # at all.
  def paired_account(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, %{} = account} ->
        %{
          display_name: account.display_name,
          ens_name: account.ens_name,
          wallet_address: account.wallet_address,
          wallet_addresses: account.wallet_addresses || []
        }

      {:ok, nil} ->
        nil
    end
  end
end
