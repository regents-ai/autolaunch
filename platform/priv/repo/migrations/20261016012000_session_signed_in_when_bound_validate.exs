defmodule Autolaunch.Repo.Migrations.SessionSignedInWhenBoundValidate do
  @moduledoc """
  Checks every existing row against `session_authorities_signed_in_when_bound`.

  Hand-written; no resource changes. `VALIDATE CONSTRAINT` outside a migration
  transaction takes only a SHARE UPDATE EXCLUSIVE lock, so sign-in reads and
  writes go on while the table is read.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute ~s(ALTER TABLE "#{prefix()}".session_authorities VALIDATE CONSTRAINT session_authorities_signed_in_when_bound)
  end

  # A validated rule cannot be made unvalidated again; dropping it
  # (`SessionSignedInWhenBound.down/0`) is the way back.
  def down, do: :ok
end
