defmodule Autolaunch.CoveredCalls.Signer do
  @moduledoc """
  The wallet a covered-call read or step is for: one of the acting account's own
  wallets, read now. The account is the one the authenticated actor names, a
  person signed in on this site or an agent signed for the person it is paired
  with; a wallet named in the request is only taken when it is one that account
  links, and with none named the account's signed-in wallet is used.

  A paired agent's steps also need the person to hold a verified wallet now
  (`verified/1`); the account that answers is the one `wallet/2` then takes, so
  each agent call reads it once. `step_wallet/2` is that rule for the steps of
  covered calls, After-hours and Earn, which a person signed in here and a
  paired agent both ask for.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{HumanAccount, VerifiedSession}
  alias Autolaunch.Actors.{Agent, Human, System}
  alias RegentChain.Address

  @doc """
  The acting account, read now, while the person holds a verified wallet, as
  `autolaunch_my_positions` asks (`VerifiedSession.current?/1`): a person whose
  wallet evidence lapsed has none to act with (`:wallet_required`), and an
  account that cannot be read is answered as `wallet/2` answers it
  (`:authentication_required`).
  """
  @spec verified(term()) ::
          {:ok, Ash.Resource.record()} | {:error, :wallet_required | :authentication_required}
  def verified(%actor{human_account_id: id}) when actor in [Human, Agent] do
    with {:ok, account} <- account(id) do
      if VerifiedSession.current?(account), do: {:ok, account}, else: {:error, :wallet_required}
    end
  end

  def verified(_actor), do: {:error, :authentication_required}

  @doc """
  The wallet the actor acts with: `candidate` when it is one of the account's
  own wallets, otherwise the one it signed in with. The account is read now, or
  is the one `verified/1` read.
  """
  @spec wallet(term(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def wallet(%actor{human_account_id: id}, candidate) when actor in [Human, Agent] do
    with {:ok, account} <- account(id), do: wallet(account, candidate)
  end

  def wallet(%HumanAccount{wallet_address: primary, wallet_addresses: addresses}, candidate) do
    with {:ok, wallet} <- candidate(candidate || primary) do
      if Enum.any?(addresses || [], &Address.equal?(&1, wallet)),
        do: {:ok, wallet},
        else: {:error, :wrong_signer}
    end
  end

  def wallet(_actor, _candidate), do: {:error, :authentication_required}

  @doc """
  The wallet a step is prepared for, as `wallet/2` takes it; for a paired
  agent, only while its person holds a verified wallet now (`verified/1`), from
  that one read of the account.
  """
  @spec step_wallet(term(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def step_wallet(%Agent{} = agent, candidate) do
    with {:ok, account} <- verified(agent), do: wallet(account, candidate)
  end

  def step_wallet(actor, candidate), do: wallet(actor, candidate)

  defp account(id) do
    case Accounts.points_account(id, actor: %System{}) do
      {:ok, account} -> {:ok, account}
      _missing -> {:error, :authentication_required}
    end
  end

  defp candidate(value) do
    case Address.normalize(value) do
      {:ok, wallet} -> {:ok, wallet}
      :error -> {:error, :wallet_required}
    end
  end
end
