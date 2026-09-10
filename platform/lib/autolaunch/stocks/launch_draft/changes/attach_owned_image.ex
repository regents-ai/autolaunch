defmodule Autolaunch.Stocks.LaunchDraft.Changes.AttachOwnedImage do
  @moduledoc false
  use Ash.Resource.Change

  alias Autolaunch.Actors.Human

  @impl true
  def change(changeset, _opts, %{actor: %Human{human_account_id: owner_id} = actor}) do
    image_id = Ash.Changeset.get_argument(changeset, :stock_launch_draft_image_id)
    draft_id = changeset.data.id

    case Autolaunch.get_my_stock_launch_draft_image_by_id(draft_id, image_id, actor: actor) do
      {:ok,
       %{id: ^image_id, human_account_id: ^owner_id, stock_launch_draft_id: ^draft_id} = image} ->
        url =
          AutolaunchWeb.Endpoint.url() <> "/stock-images/#{image.id}/#{image.digest}"

        if String.valid?(url) and byte_size(url) <= 256 do
          changeset
          |> Ash.Changeset.change_attribute(:stock_launch_draft_image_id, image.id)
          |> Ash.Changeset.change_attribute(:image, url)
        else
          unavailable(changeset)
        end

      _not_owned_by_this_draft ->
        unavailable(changeset)
    end
  end

  def change(changeset, _opts, _context), do: unavailable(changeset)

  defp unavailable(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :stock_launch_draft_image_id,
      message: "image is unavailable"
    )
  end
end
