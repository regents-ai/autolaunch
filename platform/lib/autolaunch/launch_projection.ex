defmodule Autolaunch.LaunchProjection do
  @moduledoc false

  require Ash.Query
  alias Autolaunch
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Address, LaunchAbi}
  alias Autolaunch.{Lab, LabProjection}

  @actor %System{}

  # The ledger only runs against the Base description, so the factory whose
  # launches these logs may be, the chain they are on and the REGENT they quote
  # in are the description's own.
  @spec project_logs([struct() | map()]) :: :ok | {:error, term()}
  def project_logs(logs) when is_list(logs) do
    deployment = Lab.current!()
    factory = Lab.address!(deployment, :factory)
    topic = LaunchAbi.selector(:launch_created)

    logs
    |> Enum.filter(&factory_launch_created?(&1, factory, topic))
    |> Enum.reduce_while(:ok, fn log, :ok ->
      case project_log(log, factory, deployment) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp project_log(log, factory, deployment) do
    with {:ok, event} <- decode_launch_created(log, factory),
         {:ok, operation} <- matching_operation(field(log, :transaction_hash), deployment) do
      write_auction(event, operation, deployment)
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

  defp matching_operation(transaction_hash, deployment) when is_binary(transaction_hash) do
    hash = String.downcase(transaction_hash)

    with {:ok, attempts} <-
           Autolaunch.WalletAttempt
           |> Ash.Query.filter(
             transaction_hash == ^hash and step == :launch and state == :confirmed
           )
           |> Ash.Query.load(:launch_operation)
           |> Ash.read(actor: @actor) do
      case attempts do
        [attempt | _] ->
          accepted_operation(
            %{attempt.launch_operation | result: attempt.result},
            deployment
          )

        [] ->
          {:ok, nil}
      end
    end
  end

  defp accepted_operation(%{envelope: envelope} = operation, deployment) do
    if envelope_chain_id(envelope) == deployment.chain_id,
      do: {:ok, operation},
      else: {:ok, nil}
  end

  defp envelope_chain_id(envelope) when is_map(envelope), do: envelope["chain_id"]

  defp write_auction(_event, nil, _deployment), do: :ok

  defp write_auction(event, %{envelope: %{"arguments" => arguments}} = operation, deployment) do
    recorded = operation.result["auction"]

    if Address.equal?(event.auction, recorded) do
      persist_auction(event, operation, arguments, deployment)
    else
      {:error, {:auction_mismatch, event.auction, recorded}}
    end
  end

  defp persist_auction(event, operation, arguments, deployment) do
    attrs =
      LabProjection.auction_attrs(arguments, %{
        chain_id: deployment.chain_id,
        creator_human_account_id: operation.human_account_id,
        state: :active,
        auction_address: event.auction,
        quote_token_address: Lab.address!(deployment, :regent),
        treasury_address: event.treasury
      })

    case Autolaunch.project_launch_auction(attrs, actor: @actor) do
      {:ok, _auction} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp field(log, key), do: Map.fetch!(log, key)
end
