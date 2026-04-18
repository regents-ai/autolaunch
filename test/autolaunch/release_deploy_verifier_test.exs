defmodule Autolaunch.ReleaseDeployVerifierTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.ReleaseDeployVerifier
  alias Autolaunch.ReleaseDeployVerifierTestSupport, as: Support

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])
    previous_rpc = Application.get_env(:autolaunch, :cca_rpc_adapter)
    previous_mode = Application.get_env(:autolaunch, :release_deploy_verifier_rpc_mode)

    Application.put_env(:autolaunch, :launch, Support.launch_config(previous_launch))
    Application.put_env(:autolaunch, :cca_rpc_adapter, Support.Rpc)
    Support.set_rpc_mode(:healthy)

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)

      if previous_rpc do
        Application.put_env(:autolaunch, :cca_rpc_adapter, previous_rpc)
      else
        Application.delete_env(:autolaunch, :cca_rpc_adapter)
      end

      if previous_mode do
        Application.put_env(:autolaunch, :release_deploy_verifier_rpc_mode, previous_mode)
      else
        Application.delete_env(:autolaunch, :release_deploy_verifier_rpc_mode)
      end
    end)

    %{job: Support.insert_ready_job!()}
  end

  test "verifier passes for a healthy live launch", %{job: job} do
    assert %{ok: true, job_id: job_id, controller_address: controller, checks: checks} =
             ReleaseDeployVerifier.run(job.job_id)

    assert job_id == job.job_id
    assert controller == Support.address(:controller)
    assert Enum.all?(checks, & &1.ok)

    assert Enum.map(checks, & &1.key) == [
             "job_ready",
             "controller_address",
             "controller_owner",
             "revenue_share_factory_controller_auth",
             "revenue_ingress_factory_controller_auth",
             "fee_registry_ownership",
             "fee_vault_ownership",
             "hook_ownership",
             "fee_vault_canonical_tokens",
             "strategy_migrated",
             "strategy_pool_and_position",
             "fee_hook_pool_wiring",
             "fee_vault_hook",
             "subject_registry_wiring",
             "ingress_wiring"
           ]
  end

  test "verifier fails when pending ownership is not accepted", %{job: job} do
    Support.set_rpc_mode(:pending_owner)

    assert %{ok: false, checks: checks} = ReleaseDeployVerifier.run(job.job_id)

    assert Enum.any?(
             checks,
             &(&1.key == "fee_vault_ownership" and not &1.ok and
                 String.contains?(&1.detail, "Pending owner"))
           )
  end
end
