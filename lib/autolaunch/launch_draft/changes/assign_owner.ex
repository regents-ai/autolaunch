defmodule Autolaunch.LaunchDraft.Changes.AssignOwner do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Actors.Human

  @impl true
  def change(changeset, _opts, %{actor: %Human{human_account_id: id}}) when is_integer(id) do
    Ash.Changeset.change_attribute(changeset, :human_account_id, id)
  end

  def change(changeset, _opts, _context), do: changeset
end
