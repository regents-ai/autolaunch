defmodule Autolaunch.Bid.Changes.NormalizeOwnerAddress do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :owner_address) do
      address when is_binary(address) ->
        Ash.Changeset.change_attribute(changeset, :owner_address, String.downcase(address))

      _address ->
        changeset
    end
  end
end
