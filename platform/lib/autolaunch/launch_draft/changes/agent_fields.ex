defmodule Autolaunch.LaunchDraft.Changes.AgentFields do
  @moduledoc """
  Which draft fields a paired agent set, so the creator's review can name
  each one before any wallet step. With `mark: true` (an agent's save) every
  field the save changes joins `agent_set_fields`; with `mark: false` (the
  creator's own edit) every field the creator changes leaves it. A picture is
  the field `:image`, and a chain the field `:chain`.

  `set:` names fields an earlier step of the same save changed: an agent's
  picture is stored and chosen as the creator's own upload is, and only then
  named as the agent's.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    changed =
      opts
      |> Keyword.get(:fields, [])
      |> Enum.filter(&Ash.Changeset.changing_attribute?(changeset, &1))
      |> Enum.map(&field/1)
      |> Enum.concat(Keyword.get(opts, :set, []))

    marked = Ash.Changeset.get_attribute(changeset, :agent_set_fields) || []

    fields =
      if Keyword.fetch!(opts, :mark),
        do: Enum.uniq(marked ++ changed),
        else: marked -- changed

    Ash.Changeset.force_change_attribute(changeset, :agent_set_fields, fields)
  end

  # The picture is chosen by its stored image; the review names it as the picture.
  defp field(:launch_draft_image_id), do: :image
  defp field(:stock_launch_draft_image_id), do: :image
  defp field(field), do: field
end
