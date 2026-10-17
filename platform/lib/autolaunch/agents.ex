defmodule Autolaunch.Agents do
  @moduledoc "Resolve existing local and canonical accounts without creating records on agent reads."
  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Agent, System}

  def resolve(wallet) do
    with {:ok, pairing} <- RegentAgents.Authority.resolve(Repo, wallet),
         {:ok, local} when not is_nil(local) <-
           Accounts.get_by_privy_did(pairing.privy_user_id, actor: %System{}),
         true <- Accounts.VerifiedSession.current?(local),
         {:ok, canonical} when not is_nil(canonical) <-
           Accounts.canonical_by_privy_id(pairing.privy_user_id, actor: %System{}) do
      {:ok,
       %Agent{
         wallet_address: wallet,
         privy_user_id: pairing.privy_user_id,
         pairing_id: pairing.id,
         acting_agent_id: pairing.id,
         human_account_id: canonical.id,
         local_human_account_id: local.id
       }, local}
    else
      {:ok, nil} -> {:error, :owner_not_local}
      false -> {:error, :owner_not_local}
      error -> error
    end
  end

  # How a check-in (`GET /api/agents/v1/me`) names the person's account: nil until
  # the person first signs in here, and the check-in then answers `person_not_here`.
  def paired_account(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, %{} = account} ->
        %{
          display_name: account.display_name,
          wallet_address: account.wallet_address,
          wallet_addresses: account.wallet_addresses || []
        }

      {:ok, nil} ->
        nil
    end
  end
end
