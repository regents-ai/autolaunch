defmodule Autolaunch.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ok = enforce_siwa_runtime_guard!()

    children = [
      Autolaunch.Repo,
      {DNSCluster, query: Application.get_env(:autolaunch, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Autolaunch.PubSub},
      {Task.Supervisor, name: Autolaunch.TaskSupervisor},
      AutolaunchWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Autolaunch.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    AutolaunchWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp enforce_siwa_runtime_guard! do
    runtime_env = Application.get_env(:autolaunch, :runtime_env, :dev)
    siwa_cfg = Application.get_env(:autolaunch, :siwa, [])
    skip_http_verify? = Keyword.get(siwa_cfg, :skip_http_verify, false) == true

    if skip_http_verify? and runtime_env != :test do
      raise """
      invalid SIWA configuration: :siwa, skip_http_verify may only be enabled in :test.
      """
    end

    :ok
  end
end
