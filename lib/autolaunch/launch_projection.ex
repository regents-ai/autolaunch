defmodule Autolaunch.LaunchProjection do
  @moduledoc false

  alias Autolaunch
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Abi, Address, LaunchAbi}
  alias Autolaunch.LabProjection

  @actor %System{}
  @chain_id 8453

  @spec project_logs([struct() | map()]) :: :ok | {:error, term()}
  def project_logs(logs) when is_list(logs) do
    case factory_address() do
      :none -> :ok
      {:ok, factory} -> project_factory_logs(logs, factory)
    end
  end

  @spec factory_address() :: {:ok, String.t()} | :none
  def factory_address do
    env = Application.get_env(:autolaunch, __MODULE__, [])

    case Keyword.get(env, :factory_address) do
      nil -> Abi.factory_address()
      address when is_binary(address) -> {:ok, address}
    end
  end

  defp project_factory_logs(logs, factory) do
    topic = LaunchAbi.selector(:launch_created)

    logs
    |> Enum.filter(&factory_launch_created?(&1, factory, topic))
    |> Enum.reduce_while(:ok, fn log, :ok ->
      case project_log(log, factory) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp project_log(log, factory) do
    with {:ok, event} <- decode_launch_created(log, factory),
         {:ok, operation} <- matching_operation(field(log, :transaction_hash)) do
      write_auction(event, operation)
    end
  end

  defp factory_launch_created?(log, factory, topic) do
    address = field(log, :address)
    topics = field(log, :topics)

    is_binary(address) and is_list(topics) and
      String.downcase(address) == String.downcase(factory) and
      match?([^topic | _indexed], downcased_topics(topics))
  end

  defp downcased_topics(topics), do: Enum.map(topics, &String.downcase/1)

  defp decode_launch_created(log, factory) do
    case LaunchAbi.launch_created(
           [
             %{
               "address" => field(log, :address),
               "topics" => field(log, :topics),
               "data" => field(log, :data)
             }
           ],
           factory
         ) do
      {:ok, event} -> {:ok, event}
      :error -> {:error, :undecodable_launch_created}
    end
  end

  defp matching_operation(transaction_hash) when is_binary(transaction_hash) do
    Autolaunch.chain_verified_launch_operation_by_hash(transaction_hash, actor: @actor)
    |> accepted_operation()
  end

  defp accepted_operation({:ok, %{envelope: envelope} = operation}) do
    if envelope_chain_id(envelope) == @chain_id, do: {:ok, operation}, else: {:ok, nil}
  end

  defp accepted_operation({:ok, nil}), do: {:ok, nil}
  defp accepted_operation({:error, reason}), do: {:error, reason}

  defp envelope_chain_id(envelope) when is_map(envelope), do: envelope["chain_id"]

  defp write_auction(_event, nil), do: :ok

  defp write_auction(event, %{envelope: %{"arguments" => arguments}} = operation) do
    recorded = operation.result["auction"]

    if Address.equal?(event.auction, recorded) do
      persist_auction(event, operation, arguments)
    else
      {:error, {:auction_mismatch, event.auction, recorded}}
    end
  end

  defp persist_auction(event, operation, arguments) do
    attrs =
      LabProjection.auction_attrs(arguments, %{
        projection_id: LabProjection.auction_id(event.auction),
        creator_human_account_id: operation.human_account_id,
        state: :active,
        auction_address: event.auction,
        quote_token_address: Abi.regent_address(),
        treasury_address: event.treasury
      })

    case Autolaunch.project_launch_auction(attrs, actor: @actor) do
      {:ok, _auction} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp field(log, key), do: Map.fetch!(log, key)
end
