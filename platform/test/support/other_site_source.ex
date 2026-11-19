defmodule Autolaunch.OtherSiteSource do
  @moduledoc """
  Another site's own record of an action, which this site cannot read: for a
  test that settles an event another site recorded, the action always stands,
  for the account the event was recorded for.
  """

  require Ash.Query
  alias RegentPoints.{Event, Store}

  def verify(%{"source_app" => app, "source_kind" => kind, "source_event_key" => key}) do
    [%{account_id: account_id}] =
      Event
      |> Ash.Query.filter(
        source_app == ^app and source_kind == ^kind and source_event_key == ^key
      )
      |> Ash.read!(actor: Store.system())

    {:ok, %{account_id: account_id}}
  end

  @doc "Runs `fun` with `rule_id` sourced from the other site, then puts this site's sources back."
  def settle(rule_id, fun) do
    adapters = Application.get_env(:regent_points, :adapters)
    Application.put_env(:regent_points, :adapters, Map.put(adapters, rule_id, __MODULE__))

    try do
      fun.()
    after
      Application.put_env(:regent_points, :adapters, adapters)
    end
  end
end
