defmodule Autolaunch.LaunchProjection do
  @moduledoc """
  Records every Revstake factory `LaunchCreated` the Base ledger stores as a
  `LaunchDiscovery`, inside the ledger's own commit.

  Nothing is listed here: `LaunchDiscovery`'s `:resolve` trigger matches each
  recorded launch to the review it carried out. A replayed log finds its launch
  already recorded and changes nothing.
  """

  alias Autolaunch
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.LaunchAbi
  alias Autolaunch.Lab

  @actor %System{}

  # The ledger only runs against the Base description, so the factory whose
  # launches these logs may be and the chain they are on are the description's
  # own.
  @spec project_logs([struct() | map()]) :: :ok | {:error, term()}
  def project_logs(logs) when is_list(logs) do
    deployment = Lab.current!()
    factory = Lab.address!(deployment, :factory)
    topic = LaunchAbi.selector(:launch_created)

    logs
    |> Enum.filter(&factory_launch_created?(&1, factory, topic))
    |> Enum.reduce_while(:ok, fn log, :ok ->
      case record(log, factory, deployment) do
        {:ok, _discovery} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record(log, factory, deployment) do
    with {:ok, event} <- decode_launch_created(log, factory) do
      Autolaunch.record_launch_discovery(
        %{
          launchpad: :base_revstake,
          chain_id: deployment.chain_id,
          contract: String.downcase(factory),
          launch_id: event.launch_id,
          launcher: event.launcher,
          auction: event.auction,
          transaction_hash: String.downcase(log.transaction_hash)
        },
        actor: @actor
      )
    end
  end

  defp factory_launch_created?(log, factory, topic) do
    is_binary(log.address) and is_list(log.topics) and
      String.downcase(log.address) == String.downcase(factory) and
      match?([^topic | _indexed], Enum.map(log.topics, &String.downcase/1))
  end

  defp decode_launch_created(log, factory) do
    case LaunchAbi.launch_created(
           [%{"address" => log.address, "topics" => log.topics, "data" => log.data}],
           factory
         ) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, :undecodable_launch_created}
    end
  end
end
