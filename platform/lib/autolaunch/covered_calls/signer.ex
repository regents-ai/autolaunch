defmodule Autolaunch.CoveredCalls.Signer do
  @moduledoc """
  The wallet a covered-call read or step is for: one of the acting account's own
  wallets, read now. The account is the one the authenticated actor names, a
  person signed in on this site or an agent signed for the person it is paired
  with; a wallet named in the request is only taken when it is one that account
  links, and with none named the account's signed-in wallet is used.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Agent, Human, System}
  alias RegentChain.Address

  @spec wallet(term(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def wallet(%actor{human_account_id: id}, candidate) when actor in [Human, Agent] do
    with {:ok, account} <- account(id),
         {:ok, wallet} <- candidate(candidate || account.wallet_address) do
      if Enum.any?(account.wallet_addresses || [], &Address.equal?(&1, wallet)),
        do: {:ok, wallet},
        else: {:error, :wrong_signer}
    end
  end

  def wallet(_actor, _candidate), do: {:error, :authentication_required}

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
