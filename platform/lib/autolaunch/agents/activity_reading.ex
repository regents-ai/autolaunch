defmodule Autolaunch.Agents.ActivityReading do
  @moduledoc """
  Each paired agent's reading from the sign-in service (`RegentAgents.Activity`):
  where it has been active across the Regent sites and its registry listing, as
  the template's `AshTemplate.Agents.ActivityReading` reads it. A reading is kept
  on this machine for five minutes and shared by every page that shows the
  agent, so the service is read at most once per agent in that time; a panel
  that opens while that agent's read is out waits for the same answer. The
  service answers up to 600 reads a minute from a site machine. A failed read is
  kept for one minute, so while the service is down each agent is asked again at
  most once a minute, however often the panel opens.

  A reading is kept under the agent's wallet and pairing time, so an agent paired
  again starts a fresh one. The site's own Cachex holds them, as it holds its
  other short-lived readings.

  Each read that gives no reading is counted in `health.agent_activity_unread.total`
  by its reason, such as `bad_day` for a day from the service in a shape it does
  not send.
  """

  alias RegentAgents.{Activity, PairedAgent}

  @cache __MODULE__
  @kept :timer.minutes(5)
  @failure_kept :timer.minutes(1)

  @doc "The cache the readings are kept in, started by `Autolaunch.Application`."
  def cache, do: @cache

  @spec read(PairedAgent.t()) :: {:ok, Activity.reading()} | {:error, term()}
  def read(%PairedAgent{} = agent) do
    case Cachex.fetch(@cache, {agent.wallet, agent.paired_at}, fn _key -> fresh(agent) end) do
      {status, reading} when status in [:ok, :commit] -> reading
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh(agent) do
    reading = Activity.recent(agent)
    measure(reading)
    {:commit, reading, expire: kept(reading)}
  end

  defp kept({:ok, _reading}), do: @kept
  defp kept({:error, _reason}), do: @failure_kept

  defp measure({:ok, _reading}), do: :ok

  defp measure({:error, reason}),
    do:
      :telemetry.execute([:autolaunch, :agents, :activity_unread], %{count: 1}, %{
        reason: reason(reason)
      })

  defp reason(reason)
       when reason in [:bad_day, :bad_days, :registration_unreadable, :not_configured],
       do: reason

  defp reason({:unexpected_status, _status}), do: :unexpected_status
  defp reason(_unanswered), do: :unanswered
end
