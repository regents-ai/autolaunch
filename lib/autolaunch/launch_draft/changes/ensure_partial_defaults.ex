defmodule Autolaunch.LaunchDraft.Changes.EnsurePartialDefaults do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.change_new_attribute(:name, "")
    |> Ash.Changeset.change_new_attribute(:symbol, "")
  end
end
