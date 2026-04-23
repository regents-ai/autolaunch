defmodule AutolaunchWeb.LiveUpdates do
  @moduledoc false

  @event {:autolaunch_live_update, :changed}

  @topics %{
    market: "autolaunch:updates:market",
    positions: "autolaunch:updates:positions",
    subjects: "autolaunch:updates:subjects",
    regent: "autolaunch:updates:regent",
    system: "autolaunch:updates:system"
  }

  def subscribe(topics) do
    topics
    |> List.wrap()
    |> Enum.each(fn topic -> Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic_name(topic)) end)

    :ok
  end

  def broadcast(topics) do
    topics
    |> List.wrap()
    |> Enum.each(fn topic ->
      Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic_name(topic), @event)
    end)

    :ok
  end

  def event, do: @event

  defp topic_name(topic) when is_atom(topic), do: Map.fetch!(@topics, topic)
  defp topic_name(topic) when is_binary(topic), do: topic
end
