defmodule Autolaunch.LaunchDraft.Changes.UpcaseTicker do
  @moduledoc "A ticker typed in small letters is saved in capitals."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :symbol) do
      symbol when is_binary(symbol) ->
        if Ash.Changeset.changing_attribute?(changeset, :symbol),
          do: Ash.Changeset.force_change_attribute(changeset, :symbol, String.upcase(symbol)),
          else: changeset

      _none ->
        changeset
    end
  end
end
