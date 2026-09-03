defmodule Autolaunch.Bid.Checks.VerifiedWalletOwner do
  @moduledoc false
  use Ash.Policy.FilterCheck

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.Human

  @wallet ~r/\A0x[0-9a-fA-F]{40}\z/

  @impl true
  def describe(_opts), do: "bid belongs to one of the signed-in human's verified wallets"

  @impl true
  def filter(%Human{} = actor, _context, _opts) do
    with {:ok, account} when not is_nil(account) <-
           Accounts.get_human_account(actor.human_account_id, actor: actor),
         true <- VerifiedSession.current?(account),
         wallets when wallets != [] <- verified_wallets(account) do
      expr(string_downcase(owner_address) in ^wallets)
    else
      _ -> false
    end
  end

  def filter(_actor, _context, _opts), do: false

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
