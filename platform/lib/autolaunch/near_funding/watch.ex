defmodule Autolaunch.NearFunding.Watch do
  @moduledoc """
  Follows one funding's swap: reads its status every ten seconds until the swap
  succeeds, is refunded or fails, or its deadline is fifteen minutes gone. A
  read the service could not answer is tried again with Oban's backoff.
  """
  use Oban.Worker,
    queue: :outside_calls,
    max_attempts: 10,
    unique: [keys: [:id], period: :infinity, states: :incomplete]

  alias Autolaunch.Actors.System
  alias Autolaunch.Funding

  @ended [:success, :refunded, :failed]
  @margin_s 15 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Funding.refresh_near_funding(id, actor: %System{}) do
      {:ok, %{state: state}} when state in @ended -> :ok
      {:ok, funding} -> if over?(funding), do: :ok, else: {:snooze, 10}
      {:error, error} -> {:error, error}
    end
  end

  defp over?(funding),
    do: DateTime.after?(DateTime.utc_now(), DateTime.add(funding.deadline, @margin_s))
end
