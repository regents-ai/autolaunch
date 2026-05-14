defmodule Autolaunch.Launch.Readiness.Policy do
  @moduledoc false

  @callback fetch(%{
              required(:owner_address) => String.t() | nil,
              required(:agent_id) => String.t(),
              required(:lifecycle_run_id) => String.t() | nil
            }) ::
              {:ok,
               %{
                 optional(:owner_authorized) => boolean(),
                 optional(:prior_successful_launch) => boolean(),
                 optional(:lifecycle_completed) => boolean(),
                 optional(:resolved_lifecycle_run_id) => String.t(),
                 optional(:healthy_agent_within_24h) => boolean(),
                 optional(:x_verified) => boolean(),
                 optional(:active_stake_lock_id) => String.t()
               }}
              | {:error, term()}

  def fetch(args) do
    policy_module().fetch(args)
  end

  defp policy_module do
    :autolaunch
    |> Application.get_env(:launch_readiness_policy, [])
    |> Keyword.get(:module, Autolaunch.Launch.Readiness.Policy.Unconfigured)
  end
end

defmodule Autolaunch.Launch.Readiness.Policy.Unconfigured do
  @moduledoc false

  @behaviour Autolaunch.Launch.Readiness.Policy

  @impl true
  def fetch(_args), do: {:error, :unconfigured}
end
