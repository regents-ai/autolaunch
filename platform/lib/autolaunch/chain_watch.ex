defmodule Autolaunch.ChainWatch do
  @moduledoc """
  Every minute (`config :autolaunch, Oban, cron:`), makes sure each chain
  reading has its job: every listed auction's bids (`Autolaunch.AuctionActivity`),
  every listed token's trades (`Autolaunch.TokenTrades`) and each configured
  chain's ledger (`Autolaunch.Indexer.ReadChain`). A reading job is unique while
  it is incomplete, so inserting it again leaves a waiting or running one alone;
  a new auction or token is read within a minute of being listed.

  Each reader brings its jobs forward when a person's on-chain press lands
  (`Autolaunch.ChainRefresh`) through `soon/1`.
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Autolaunch.{AuctionActivity, ChainRefresh, TokenTrades}
  alias Autolaunch.Indexer.ReadChain

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    (AuctionActivity.jobs() ++ TokenTrades.jobs() ++ ReadChain.jobs())
    |> Enum.each(&Oban.insert!/1)
  end

  @doc """
  Makes sure the reading job `changeset` describes exists, and brings it forward
  to the ten-second gap (`ChainRefresh.gap_s/0`) when it waits longer. A job due
  sooner, or running, keeps its time, so presses that keep coming never put the
  read off.
  """
  @spec soon(Ecto.Changeset.t()) :: :ok
  def soon(changeset) do
    soon = DateTime.add(DateTime.utc_now(), ChainRefresh.gap_s())
    changeset |> Oban.insert!() |> bring_forward(soon)
  end

  defp bring_forward(%Oban.Job{state: state, scheduled_at: at} = job, soon)
       when state in ["scheduled", "retryable"] do
    if DateTime.after?(at, soon), do: {:ok, _job} = Oban.update_job(job, %{scheduled_at: soon})
    :ok
  end

  defp bring_forward(%Oban.Job{}, _soon), do: :ok
end
