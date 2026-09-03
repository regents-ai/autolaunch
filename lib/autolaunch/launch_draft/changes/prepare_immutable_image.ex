defmodule Autolaunch.LaunchDraftImage.Changes.PrepareImmutableImage do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Actors.Human
  alias Autolaunch.LaunchDraft.ImageValidator

  @impl true
  def change(changeset, _opts, %{actor: %Human{} = actor}) do
    bytes = Ash.Changeset.get_attribute(changeset, :bytes)
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    original_filename = Ash.Changeset.get_attribute(changeset, :original_filename)
    draft_id = Ash.Changeset.get_attribute(changeset, :launch_draft_id)

    with :ok <- validate_owned_draft(draft_id, actor),
         :ok <- validate_filename(original_filename),
         {:ok, _content_type} <- ImageValidator.validate(bytes, content_type) do
      changeset
      |> Ash.Changeset.change_attribute(:byte_size, byte_size(bytes))
      |> Ash.Changeset.change_attribute(:digest, sha256(bytes))
    else
      {:error, :draft_unavailable} ->
        Ash.Changeset.add_error(changeset,
          field: :launch_draft_id,
          message: "draft is unavailable"
        )

      {:error, :invalid_filename} ->
        Ash.Changeset.add_error(changeset,
          field: :original_filename,
          message: "must be valid text between 1 and 255 bytes"
        )

      {:error, reason} ->
        changeset
        |> Ash.Changeset.add_error(
          field: :bytes,
          message: Atom.to_string(reason)
        )
    end
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :launch_draft_id,
      message: "draft is unavailable"
    )
  end

  defp validate_owned_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft(draft_id, actor: actor) do
      {:ok, %{id: ^draft_id}} -> :ok
      _unavailable -> {:error, :draft_unavailable}
    end
  end

  defp validate_filename(value)
       when is_binary(value) and value != "" and byte_size(value) <= 255 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_filename}
  end

  defp validate_filename(_value), do: {:error, :invalid_filename}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
