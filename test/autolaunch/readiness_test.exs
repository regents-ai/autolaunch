defmodule Autolaunch.Launch.ReadinessTest do
  use ExUnit.Case, async: false

  alias Autolaunch.Launch.Readiness

  @owner "0x1111111111111111111111111111111111111111"

  setup do
    previous_policy = Application.get_env(:autolaunch, :launch_readiness_policy)
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(:autolaunch, :launch_readiness_policy, module: __MODULE__.Policy)

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.put(previous_launch, :allow_unverified_owner, false)
    )

    on_exit(fn ->
      restore_env(:launch_readiness_policy, previous_policy)
      Application.put_env(:autolaunch, :launch, previous_launch)
    end)
  end

  test "passed_count counts true checks only" do
    readiness = %{checks: [%{passed: true}, %{passed: false}, %{passed: true}]}

    assert Readiness.passed_count(readiness) == 2
  end

  test "collect uses the configured policy boundary for launch readiness signals" do
    readiness =
      Readiness.collect(%{
        owner_address: String.upcase(@owner),
        agent_id: "agent_1",
        lifecycle_run_id: "run_1",
        vesting_beneficiary: @owner,
        beneficiary_confirmed: true
      })

    assert readiness.ready_to_launch
    assert readiness.resolved_lifecycle_run_id == "run_1"
    assert readiness.stake_lock_id == "stake_1"
    assert Readiness.passed_count(readiness) == 8

    assert_receive {:policy_fetch,
                    %{
                      owner_address: @owner,
                      agent_id: "agent_1",
                      lifecycle_run_id: "run_1"
                    }}
  end

  test "collect fails closed when the shared policy boundary is unavailable" do
    Application.put_env(:autolaunch, :launch_readiness_policy,
      module: __MODULE__.UnavailablePolicy
    )

    readiness =
      Readiness.collect(%{
        owner_address: @owner,
        agent_id: "agent_1",
        lifecycle_run_id: nil,
        vesting_beneficiary: @owner,
        beneficiary_confirmed: true
      })

    refute readiness.ready_to_launch
    assert readiness.blocking_status_code == 503
    assert readiness.stake_lock_id == nil
  end

  test "readiness does not query cross-product launch policy schemas directly" do
    source = File.read!("lib/autolaunch/launch/readiness.ex")

    refute source =~ "Autolaunch.Launch.External."
    refute source =~ "Repo."
  end

  defp restore_env(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore_env(key, value), do: Application.put_env(:autolaunch, key, value)

  defmodule Policy do
    @behaviour Autolaunch.Launch.Readiness.Policy

    @impl true
    def fetch(args) do
      send(self(), {:policy_fetch, args})

      {:ok,
       %{
         owner_authorized: true,
         prior_successful_launch: false,
         lifecycle_completed: true,
         resolved_lifecycle_run_id: "run_1",
         healthy_agent_within_24h: true,
         x_verified: true,
         active_stake_lock_id: "stake_1"
       }}
    end
  end

  defmodule UnavailablePolicy do
    @behaviour Autolaunch.Launch.Readiness.Policy

    @impl true
    def fetch(_args), do: {:error, :unavailable}
  end
end
