defmodule Autolaunch.Repo do
  use AshPostgres.Repo,
    otp_app: :autolaunch

  @impl true
  def installed_extensions do
    ["ash-functions"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 14, minor: 20, patch: 0}
  end
end
