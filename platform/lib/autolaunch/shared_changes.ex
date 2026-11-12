defmodule Autolaunch.SharedChanges do
  @moduledoc """
  Changes made on any Regent site reach this site's open pages: a pairing made or
  ended (`RegentAgents.Listener`) arrives as a database notice. It listens on a
  connection of the site's own, `Autolaunch.Notifications`, on the database's
  direct address (`Autolaunch.DatabaseConfig.notifications_config!/2`), since a
  pooler drops `LISTEN`. The connection starts first, so a new connection brings a
  new listener.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    connection = Application.fetch_env!(:autolaunch, Autolaunch.Notifications)

    children = [
      {Postgrex.Notifications, [name: Autolaunch.Notifications] ++ connection},
      RegentAgents.Listener
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
