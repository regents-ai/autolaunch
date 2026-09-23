defmodule Autolaunch.Auction.Changes.ImageColor do
  @moduledoc "Keeps the colour of the auction's image beside its address, for its cards."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    image = Ash.Changeset.get_attribute(changeset, :image)

    Ash.Changeset.force_change_attribute(
      changeset,
      :image_color,
      Autolaunch.ImageColor.for_url(image)
    )
  end
end
