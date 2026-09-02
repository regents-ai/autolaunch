defmodule Autolaunch.Accounts.Changes.RefreshWalletEvidence do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    addresses = Ash.Changeset.get_argument(changeset, :wallet_addresses)
    primary = Ash.Changeset.get_argument(changeset, :wallet_address)

    if is_list(addresses) do
      changeset
      |> Ash.Changeset.change_attribute(:wallet_address, primary)
      |> Ash.Changeset.change_attribute(:wallet_addresses, addresses)
    else
      changeset
    end
  end
end
