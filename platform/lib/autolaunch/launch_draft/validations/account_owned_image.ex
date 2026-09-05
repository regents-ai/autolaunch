defmodule Autolaunch.LaunchDraft.Validations.AccountOwnedImage do
  @moduledoc false
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Autolaunch.LaunchDraft

  @impl true
  def validate(changeset, _opts, _context) do
    draft = changeset.data

    if Ash.Changeset.changing_attribute?(changeset, :image) or
         not LaunchDraft.image_complete?(draft) do
      {:error,
       InvalidAttribute.exception(
         field: :image,
         message: "is managed by this account's immutable image upload"
       )}
    else
      :ok
    end
  end
end
