defmodule Autolaunch.Agents.HostedAddress do
  @moduledoc """
  The wallet of each account's hosted identity: the one identity an app such as
  Claude keeps when its person connects it here, held by the sign-in service.
  It never changes for an account on this site, so the service is asked once
  per account on each machine (`RegentMCPAgents.address/1`) and the answer is
  kept here; every later call from the app reads it from this table. When the
  service could not answer, the account is asked again a minute later, never
  sooner, however often its app calls meanwhile.
  """

  use GenServer

  @table __MODULE__
  @again_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The wallet of the identity the connection's account keeps here."
  @spec fetch(map()) :: {:ok, String.t()} | {:error, :unavailable}
  def fetch(%{subject: subject} = principal) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, subject) do
      [{^subject, {:ok, address}}] -> {:ok, address}
      [{^subject, {:unavailable, until}}] when until > now -> {:error, :unavailable}
      _none_or_old -> ask(principal, now)
    end
  end

  # Two calls that miss at once both ask; the service gives both the same wallet.
  defp ask(%{subject: subject} = principal, now) do
    case RegentMCPAgents.address(principal) do
      {:ok, address} ->
        :ets.insert(@table, {subject, {:ok, address}})
        {:ok, address}

      {:error, _reason} ->
        :ets.insert(@table, {subject, {:unavailable, now + @again_ms}})
        {:error, :unavailable}
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
