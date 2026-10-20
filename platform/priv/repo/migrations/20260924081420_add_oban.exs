defmodule Autolaunch.Repo.Migrations.AddOban do
  @moduledoc """
  The background job tables, in the schema every Autolaunch table lives in.
  The release creates that schema before it migrates, so this does not.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14, prefix: prefix(), create_schema: false)

  def down, do: Oban.Migration.down(version: 1, prefix: prefix())
end
