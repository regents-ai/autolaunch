defmodule Autolaunch.Repo.Migrations.AddOban do
  @moduledoc """
  The background job tables, in the schema every Autolaunch table lives in.
  `mix autolaunch.schema.create` makes that schema, so this does not.
  """

  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14, prefix: prefix(), create_schema: false)

  def down, do: Oban.Migration.down(version: 1, prefix: prefix())
end
