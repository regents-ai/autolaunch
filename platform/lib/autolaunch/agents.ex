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

  def paired_account(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, nil} ->
        %{local_account: false, sign_in: "https://autolaunch.sh/profile"}

      {:ok, account} ->
        case Accounts.canonical_by_privy_id(privy_id, actor: %System{}) do
          {:ok, canonical} when not is_nil(canonical) ->
            %{
              local_account: Accounts.VerifiedSession.current?(account),
              display_name: account.display_name
            }

          _ ->
            %{local_account: false, sign_in: "https://autolaunch.sh/profile"}
        end

      _ ->
        %{local_account: false}
    end
  end
end
