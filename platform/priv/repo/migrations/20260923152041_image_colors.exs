defmodule Autolaunch.Repo.Migrations.ImageColors do
  @moduledoc """
  Gives every stored launch image its colour, and every auction the colour of
  its image. Existing images are read once here; new ones get theirs when stored.
  """

  use Ecto.Migration

  def up do
    alter table(:auctions) do
      add :image_color, :text
    end

    alter table(:launch_draft_images) do
      add :color, :text
    end

    alter table(:stock_launch_draft_images) do
      add :color, :text
    end

    flush()

    # The tables live in the schema the migration runs in, which is not `public`
    # in production, so the hand-written SQL names it explicitly.
    schema = ~s("#{prefix()}")

    for table <- ["launch_draft_images", "stock_launch_draft_images"] do
      %{rows: ids} = repo().query!("SELECT id FROM #{schema}.#{table}")

      for [id] <- ids do
        %{rows: [[bytes]]} =
          repo().query!("SELECT bytes FROM #{schema}.#{table} WHERE id = $1", [id])

        {:ok, color} = Autolaunch.ImageColor.dominant(bytes)
        repo().query!("UPDATE #{schema}.#{table} SET color = $2 WHERE id = $1", [id, color])
      end
    end

    for {table, lane} <- [
          {"launch_draft_images", "images"},
          {"stock_launch_draft_images", "stock-images"}
        ] do
      execute """
      UPDATE #{schema}.auctions AS auction
      SET image_color = image.color
      FROM #{schema}.#{table} AS image
      WHERE split_part(auction.image, '/', -3) = '#{lane}'
        AND split_part(auction.image, '/', -2) = image.id::text
        AND split_part(auction.image, '/', -1) = image.digest
      """
    end

    alter table(:launch_draft_images) do
      modify :color, :text, null: false
    end

    alter table(:stock_launch_draft_images) do
      modify :color, :text, null: false
    end
  end

  def down do
    alter table(:stock_launch_draft_images) do
      remove :color
    end

    alter table(:launch_draft_images) do
      remove :color
    end

    alter table(:auctions) do
      remove :image_color
    end
  end
end
