defmodule Autolaunch.LaunchRunnerHardeningTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

    :ok
  end

  test "process_job accepts the last valid marked deploy payload even with noisy output" do
    payload =
      canonical_launch_output(
        strategyAddress: "0x1234512345123451234512345123451234512345",
        defaultIngressAddress: "0x7777777777777777777777777777777777777777"
      )

    first_payload =
      canonical_launch_output(strategyAddress: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    lines = [
      "starting forge output",
      "CCA_RESULT_JSON:not-json",
      "prefix CCA_RESULT_JSON:#{Jason.encode!(first_payload)}",
      "more unrelated logs",
      "CCA_RESULT_JSON:#{Jason.encode!(payload)}"
    ]

    with_launch_command_lines(lines, fn ->
      insert_launch_job("job_noisy_output")

      assert :ok = Launch.process_job("job_noisy_output")

      job = Repo.get!(Job, "job_noisy_output")

      assert job.status == "ready"
      assert job.strategy_address == "0x1234512345123451234512345123451234512345"
      assert job.default_ingress_address == "0x7777777777777777777777777777777777777777"
    end)
  end

  test "process_job fails when the deploy command exceeds the configured timeout" do
    with_launch_script(
      """
      #!/bin/sh
      exit 0
      """,
      [deploy_timeout_ms: 50, command_runner_module: __MODULE__.TimeoutCommandStub],
      fn ->
        insert_launch_job("job_timeout")

        assert :ok = Launch.process_job("job_timeout")

        job = Repo.get!(Job, "job_timeout")

        assert job.status == "failed"
        assert job.error_message == "Forge timed out while waiting for deployment."
      end
    )
  end

  defp insert_launch_job(job_id) do
    now = DateTime.utc_now()

    {:ok, _job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: job_id,
        owner_address: "0x1111111111111111111111111111111111111111",
        agent_id: "84532:42",
        agent_name: "Atlas",
        token_name: "Atlas Coin",
        token_symbol: "ATLAS",
        network: "base-sepolia",
        chain_id: 84_532,
        status: "queued",
        step: "queued",
        total_supply: "1000",
        message: "signed",
        siwa_nonce: "nonce-1",
        siwa_signature: "sig",
        issued_at: now,
        broadcast: false,
        agent_safe_address: "0x1111111111111111111111111111111111111111"
      })
      |> Repo.insert()
  end

  defp with_launch_command_lines(lines, fun) do
    script_lines = Enum.map(lines, fn line -> "printf '%s\\n' '#{line}'" end)
    script = Enum.join(["#!/bin/sh" | script_lines], "\n")
    with_launch_script(script, [], fun)
  end

  defp with_launch_script(script, launch_overrides, fun) do
    original = Application.get_env(:autolaunch, :launch, [])
    tmp_dir = System.tmp_dir!()
    script_path = Path.join(tmp_dir, "launch-hardening-#{System.unique_integer([:positive])}.sh")

    File.write!(script_path, script)
    File.chmod!(script_path, 0o755)

    Application.put_env(
      :autolaunch,
      :launch,
      original
      |> Keyword.merge(
        mock_deploy: false,
        deploy_binary: script_path,
        deploy_workdir: tmp_dir,
        deploy_script_target: "ignored",
        deploy_timeout_ms: 180_000,
        rpc_url: "http://127.0.0.1:8545",
        revenue_share_factory_address: "0x1111111111111111111111111111111111111111",
        revenue_ingress_factory_address: "0x2222222222222222222222222222222222222222",
        lbp_strategy_factory_address: "0x6666666666666666666666666666666666666666",
        token_factory_address: "0x7777777777777777777777777777777777777777",
        pool_manager_address: "0x3333333333333333333333333333333333333333",
        cca_factory_address: "0x4444444444444444444444444444444444444444",
        usdc_address: "0x5555555555555555555555555555555555555555",
        position_manager_address: "0x8888888888888888888888888888888888888888"
      )
      |> Keyword.merge(launch_overrides)
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, original)
      File.rm(script_path)
    end)

    fun.()
  end

  defp canonical_launch_output(overrides) when is_list(overrides) do
    canonical_launch_output(Map.new(overrides))
  end

  defp canonical_launch_output(overrides) do
    Map.merge(
      %{
        "factoryAddress" => "0x4444444444444444444444444444444444444444",
        "auctionAddress" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "tokenAddress" => "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "strategyAddress" => "0x9999999999999999999999999999999999999999",
        "vestingWalletAddress" => "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "hookAddress" => "0xcccccccccccccccccccccccccccccccccccccccc",
        "launchFeeRegistryAddress" => "0xdddddddddddddddddddddddddddddddddddddddd",
        "feeVaultAddress" => "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        "subjectRegistryAddress" => "0xffffffffffffffffffffffffffffffffffffffff",
        "subjectId" => "0x" <> String.duplicate("1", 64),
        "revenueShareSplitterAddress" => "0x9999999999999999999999999999999999999999",
        "defaultIngressAddress" => "0x7777777777777777777777777777777777777777",
        "poolId" => "0x" <> String.duplicate("f", 64),
        "txHash" => "0x" <> String.duplicate("a", 64)
      },
      overrides
    )
  end

  defmodule TimeoutCommandStub do
    def cmd(_binary, _args, _opts) do
      Process.sleep(200)
      {"", 0}
    end
  end
end
