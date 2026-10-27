defmodule Autolaunch.SharedChanges do
  @moduledoc """
  Changes made on any Regent site reach this site's open pages: a Credits balance
  (`RegentCredits.Listener`) and a pairing made or ended (`RegentAgents.Listener`)
  arrive as database notices. Both listen on one connection of the site's own,
  `Autolaunch.Notifications` (`Autolaunch.DatabaseConfig.notifications_config!/2`).
  The connection starts first, so a new connection brings new listeners.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    connection = Application.fetch_env!(:autolaunch, Autolaunch.Notifications)

    children = [
      {Postgrex.Notifications, [name: Autolaunch.Notifications] ++ connection},
      RegentCredits.Listener,
      RegentAgents.Listener
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
