defmodule Autolaunch.Agents do
  @moduledoc """
  Reads the shared Regent account an agent's pairing names, without creating
  records on agent reads. A person's shared account exists on every Regent
  site from their first sign-in on any of them.
  """
  alias Autolaunch.{Accounts, Repo}
  alias Autolaunch.Actors.{Agent, System}
  alias AutolaunchWeb.{AccountUnavailableError, AgentNotPairedError, ReadFailure}

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
  # account. A pairing that names no Regent account pairs the agent with
  # nobody, the 403 `agent_not_paired` (`AutolaunchWeb.AgentNotPairedError`);
  # an account that could not be read just now is the 503 `account_unavailable`
  # (`AutolaunchWeb.AccountUnavailableError`).
  def paired_account(privy_id) do
    case person(privy_id) do
      {:ok, account} ->
        %{
          display_name: account.display_name,
          ens_name: account.ens_name,
          wallet_address: account.wallet_address,
          wallet_addresses: account.wallet_addresses || []
        }

      {:error, :not_paired} ->
        raise AgentNotPairedError

      {:error, :account_unavailable} ->
        raise AccountUnavailableError
    end
  end

  # The person's shared account, or `:not_paired` when the pairing names none;
  # a read that fails is logged by kind and module only and answered as
  # unavailable.
  defp person(privy_id) do
    case Accounts.get_by_privy_did(privy_id, actor: %System{}) do
      {:ok, %{} = account} ->
        {:ok, account}

      {:ok, nil} ->
        {:error, :not_paired}

      {:error, error} ->
        ReadFailure.log("agent's person read", error)
        {:error, :account_unavailable}
    end
  end
end
