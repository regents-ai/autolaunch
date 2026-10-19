defmodule Autolaunch.Agents do
  @moduledoc """
  Reads the shared Regent account an agent's pairing names, without creating
  records on agent reads. A person's shared account exists on every Regent
  site from their first sign-in on any of them.
  """
  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Agent, System}
  alias AutolaunchWeb.{AccountUnavailableError, ReadFailure}

  def resolve(wallet) do
    with {:ok, pairing} <- RegentAgents.Authority.resolve(Repo, wallet),
         {:ok, account} <- person(pairing.privy_user_id) do
      {:ok,
       %Agent{
         wallet_address: wallet,
         privy_user_id: pairing.privy_user_id,
         pairing_id: pairing.id,
         acting_agent_id: pairing.id,
         human_account_id: account.id
       }, account}
    end
  end

  # How a check-in (`GET /api/agents/v1/me`) and an agent's status
  # (`GET /api/agents/v1/whoami`) name the person's account: their shared
  # account, or nil only when the Privy identity has no shared account at all.
  # The shared requests take an account or nil, so an account that could not
  # be read just now is the agent's 503 `account_unavailable`
  # (`AutolaunchWeb.AccountUnavailableError`), never a missing person.
  def paired_account(privy_id) do
    case person(privy_id) do
      {:ok, account} ->
        %{
          display_name: account.display_name,
          ens_name: account.ens_name,
          wallet_address: account.wallet_address,
          wallet_addresses: account.wallet_addresses || []
        }

      {:error, :person_not_here} ->
        nil

      {:error, :account_unavailable} ->
        raise AccountUnavailableError
    end
  end

  # The person's shared account; a read that fails is logged by kind and
  # module only and answered as unavailable.
  defp person(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, %{} = account} ->
        {:ok, account}

      {:ok, nil} ->
        {:error, :person_not_here}

      {:error, error} ->
        ReadFailure.log("agent's person read", error)
        {:error, :account_unavailable}
    end
  end
end
