defmodule Autolaunch.LaunchDraft.Changes.ConfirmAgentTreasury do
  @moduledoc """
  The creator confirms the Safe or smart contract account their paired agent
  chose as the treasury, and the treasury is theirs from then on, as if they
  had chosen it. The draft is read again under its lock first, as the
  creator's own, so a treasury the agent changed after the page showed it is
  never confirmed in its place.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Autolaunch.LaunchDraft
  alias RegentChain.Address

  @impl true
  def change(changeset, _opts, context) do
    shown = Ash.Changeset.get_argument(changeset, :treasury)

    Ash.Changeset.before_action(changeset, &confirm_shown(&1, shown, context.actor))
  end

  defp confirm_shown(changeset, shown, actor) do
    with {:ok, draft} <-
           Autolaunch.get_my_launch_draft_for_update(changeset.data.id, actor: actor),
         true <- LaunchDraft.treasury_confirmation_needed?(draft),
         true <- Address.equal?(draft.treasury, shown) do
      confirm(%{changeset | data: draft}, draft)
    else
      _changed -> changed(changeset)
    end
  end

  defp confirm(changeset, draft),
    do:
      Ash.Changeset.force_change_attribute(
        changeset,
        :agent_set_fields,
        draft.agent_set_fields -- [:treasury, :treasury_path]
      )

  defp changed(changeset),
    do:
      Ash.Changeset.add_error(
        changeset,
        InvalidArgument.exception(field: :treasury, message: "treasury_changed")
      )
end
