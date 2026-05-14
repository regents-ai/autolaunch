defmodule Autolaunch.Application do
  @moduledoc false

  use Application

  alias Autolaunch.Siwa.Config, as: SiwaConfig

  @impl true
  def start(_type, _args) do
    :ok = enforce_siwa_runtime_guard!()
    :ok = add_sentry_logger_handler()

    children =
      [
        Autolaunch.Repo,
        Autolaunch.LocalCache.child_spec(),
        {DNSCluster, query: Application.get_env(:autolaunch, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Autolaunch.PubSub},
        {Task.Supervisor, name: Autolaunch.TaskSupervisor},
        launch_job_poller_child(),
        auction_sync_poller_child(),
        AutolaunchWeb.RateLimiter,
        Autolaunch.XmtpIdentity,
        AutolaunchWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: Autolaunch.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AutolaunchWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @doc false
  def enforce_siwa_runtime_guard! do
    runtime_env = Application.get_env(:autolaunch, :runtime_env, :dev)

    if runtime_env == :prod do
      case SiwaConfig.fetch_http_config() do
        {:ok, _config} ->
          :ok

        {:error, reason} ->
          raise """
          invalid SIWA configuration: #{inspect(reason)}
          """
      end
    end

    :ok
  end

  defp launch_job_poller_child do
    opts = Application.get_env(:autolaunch, :launch_job_poller, [])

    if Keyword.get(opts, :enabled, false) do
      {Autolaunch.Launch.JobPoller, opts}
    end
  end

  defp auction_sync_poller_child do
    opts = Application.get_env(:autolaunch, :auction_sync, [])

    if Keyword.get(opts, :enabled, false) do
      {Autolaunch.Launch.AuctionSyncPoller, opts}
    end
  end

  defp add_sentry_logger_handler do
    case :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
           config: %{metadata: [:file, :line, :request_id]}
         }) do
      :ok -> :ok
      {:error, {:already_exists, :sentry_handler}} -> :ok
    end
  end
end
