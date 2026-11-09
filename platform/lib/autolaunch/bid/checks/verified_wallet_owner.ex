defmodule Autolaunch.Bid.Checks.VerifiedWalletOwner do
  @moduledoc false
  use Ash.Policy.FilterCheck

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.{Agent, Human, System}

  @wallet ~r/\A0x[0-9a-fA-F]{40}\z/

  @impl true
  def describe(_opts), do: "bid belongs to one of the signed-in human's verified wallets"

  @impl true
  def filter(%Human{} = actor, _context, _opts) do
    case Accounts.get_human_account(actor.human_account_id, actor: actor) do
      {:ok, %{} = account} -> owned_by(account)
      _unread -> false
    end
  end

  def filter(%Agent{privy_user_id: privy_user_id, human_account_id: id}, _context, _opts) do
    case Accounts.get_by_privy_did(privy_user_id, actor: %System{}) do
      {:ok, %{id: ^id} = account} -> owned_by(account)
      _unread_or_another_account -> false
    end
  end

  def filter(_actor, _context, _opts), do: false

  defp owned_by(account) do
    with true <- VerifiedSession.current?(account),
         wallets when wallets != [] <- verified_wallets(account) do
      expr(string_downcase(owner_address) in ^wallets)
    else
      _ -> false
    end
  end

  defp verified_wallets(account) do
    account.wallet_addresses
    |> Enum.map(&normalize_wallet/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_wallet(wallet) when is_binary(wallet) do
    wallet = String.trim(wallet)
    if Regex.match?(@wallet, wallet), do: String.downcase(wallet)
  end

  defp normalize_wallet(_wallet), do: nil
end
