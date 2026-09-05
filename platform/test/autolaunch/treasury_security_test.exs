defmodule Autolaunch.TreasurySecurityTest do
  use AutolaunchWeb.ConnCase, async: false

  import Ecto.Query

  alias Autolaunch.Actors.System
  alias Autolaunch.Repo
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: Client
  alias Autolaunch.{TreasurySecurity, TreasurySecurityReport}

  @safe "0x9999999999999999999999999999999999999999"
  @concurrent_safe "0x8888888888888888888888888888888888888888"

  defmodule ConcurrentClient do
    @behaviour Autolaunch.TreasuryChainClient

    @impl true
    def canonical?(_number, _hash), do: true

    @impl true
    def observe(address, evidence) do
      test = Application.fetch_env!(:autolaunch, :test_treasury_observation_coordinator)
      send(test, {:treasury_observe, self(), address, evidence})

      receive do
        {:treasury_observation, observation} -> {:ok, observation}
      after
        5_000 -> {:error, :observation_fixture_timeout}
      end
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
      Application.delete_env(:autolaunch, :test_treasury_observation_coordinator)
    end)

    :ok
  end

  test "VERIFIED_MEANS_EXACT_2_OF_3_AND_THREE_HISTORICAL_PROOFS" do
    report = Client.seed_verified!(@safe)

    assert report.classification == :supported_safe
    assert report.verification_state == :verified
    assert report.owner_count == 3
    assert report.threshold == 2
    assert report.modules == []
  end

  test "COMPLETE_EVIDENCE_AT_THE_SAME_BLOCK_CREATES_A_NEW_IMMUTABLE_REPORT" do
    Client.install()

    assert {:ok, incomplete} =
             Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})

    assert incomplete.verification_state == :unverified

    assert {:ok, complete} =
             Autolaunch.observe_treasury_security(
               @safe,
               %{
                 usdc: "0x" <> String.duplicate("11", 32),
                 regent: "0x" <> String.duplicate("22", 32),
                 outbound: "0x" <> String.duplicate("33", 32)
               },
               actor: %System{}
             )

    assert complete.verification_state == :verified
    assert complete.source_block_hash == incomplete.source_block_hash
    assert complete.configuration_fingerprint == incomplete.configuration_fingerprint
    refute complete.id == incomplete.id

    assert {:ok, unchanged} =
             Autolaunch.get_treasury_security_report(incomplete.id, actor: nil)

    assert unchanged.verification_state == :unverified
  end

  test "EOA_AND_INTERFACE_FREE_CONTRACTS_STAY_UNVERIFIED" do
    Client.install(runtime_code: "0x", admitted_safe?: false, owners: [], threshold: nil)
    assert {:ok, eoa} = Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})
    assert {eoa.classification, eoa.verification_state} == {:eoa, :unverified}

    Client.install(
      runtime_code: "0x6001",
      runtime_identity: "0x" <> String.duplicate("55", 32),
      admitted_safe?: false,
      owners: [],
      threshold: nil
    )

    assert {:ok, unknown} =
             Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})

    assert {unknown.classification, unknown.verification_state} ==
             {:unknown_contract, :unverified}
  end

  test "BLANK_OPTIONAL_EVIDENCE_IS_ABSENT_AT_THE_OBSERVATION_BOUNDARY" do
    Client.install(runtime_code: "0x", admitted_safe?: false, owners: [], threshold: nil)

    assert {:ok, report} =
             Autolaunch.observe_treasury_security(
               @safe,
               %{"usdc" => "", "regent" => "", "outbound" => ""},
               actor: %System{}
             )

    assert report.classification == :eoa
    assert report.verification_state == :unverified
    assert report.usdc_evidence == nil
    assert report.regent_evidence == nil
    assert report.outbound_evidence == nil
  end

  test "CLASSIFICATION_PRECEDENCE_IS_CLOSED_AND_NEVER_GUESSES_FROM_SAFE_SHAPE" do
    cases = [
      {[runtime_code: "0xef0100" <> String.duplicate("11", 20)], :delegated_eoa},
      {[
         runtime_code: "0xef0100" <> String.duplicate("11", 19),
         admitted_safe?: false
       ], :unknown_contract},
      {[admitted_safe?: true, owners: [hd(owners())], threshold: 1], :safe_1_of_1},
      {[admitted_safe?: false, admitted_split?: true, owners: [], threshold: nil], :split},
      {[admitted_safe?: false, admitted_split?: false, owners: [], threshold: nil],
       :unknown_contract}
    ]

    for {overrides, classification} <- cases do
      Client.install(overrides)
      assert {:ok, report} = Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})
      assert report.classification == classification
      assert report.verification_state == :unverified
    end
  end

  test "EVERY_SAFE_CONFIGURATION_DEVIATION_STAYS_HIGH_RISK_AND_UNVERIFIED" do
    cases = [
      {[owners: Enum.take(owners(), 2)], "safe_owner_count"},
      {[owners: [hd(owners()), hd(owners()), List.last(owners())]], "safe_duplicate_owners"},
      {[threshold: 1], "safe_threshold"},
      {[modules: [hd(owners())]], "safe_modules_enabled"},
      {[guard: hd(owners())], "safe_guard_enabled"},
      {[fallback_admitted?: false], "safe_fallback_unadmitted"}
    ]

    for {overrides, reason} <- cases do
      report = Client.seed_verified!(@safe, overrides)
      assert report.verification_state == :unverified
      assert report.verification_reason == reason
    end
  end

  test "ALL_THREE_HISTORICAL_PROOFS_ARE_REQUIRED" do
    Client.install()

    for {evidence, reason} <- [
          {%{}, "usdc_evidence_missing"},
          {%{usdc: tx_hash("11")}, "regent_evidence_missing"},
          {%{usdc: tx_hash("11"), regent: tx_hash("22")}, "outbound_evidence_missing"}
        ] do
      assert {:ok, report} =
               Autolaunch.observe_treasury_security(@safe, evidence, actor: %System{})

      assert report.verification_state == :unverified
      assert report.verification_reason == reason
    end
  end

  test "REVALIDATION_REJECTS_REORGS_AND_ACCEPTS_A_NEWER_IDENTICAL_SECURITY_STATE" do
    verified = Client.seed_verified!(@safe)

    Client.install(canonical?: false)

    assert {:error, :treasury_source_reorged} =
             Autolaunch.TreasurySecurity.revalidate_bound(verified)

    Client.install(
      block_number: 30_000_001,
      block_hash: tx_hash("ef"),
      canonical_hashes: [verified.source_block_hash, tx_hash("ef")]
    )

    assert {:ok, newer} =
             Autolaunch.TreasurySecurity.revalidate_bound(verified)

    refute newer.id == verified.id
    assert newer.configuration_fingerprint == verified.configuration_fingerprint
    assert newer.verification_state == :verified
  end

  test "CONFIGURATION_DRIFT_CREATES_AN_IMMUTABLE_DOWNGRADE" do
    verified = Client.seed_verified!(@safe)

    Client.install(
      block_number: 30_000_001,
      block_hash: "0x" <> String.duplicate("ef", 32),
      threshold: 1
    )

    assert {:ok, changed} =
             Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})

    assert changed.downgrade_state == :downgraded
    assert changed.prior_verified_fingerprint == verified.configuration_fingerprint
    assert verified.verification_state == :verified
  end

  test "PERMANENT_DOWNGRADE_SURVIVES_A_VERIFIED_CHANGED_VERIFIED_SEQUENCE" do
    verified = Client.seed_verified!(@safe)

    Client.install(block_number: 30_000_001, block_hash: tx_hash("ef"), threshold: 1)

    assert {:ok, changed} =
             Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})

    restored =
      Client.seed_verified!(@safe,
        block_number: 30_000_002,
        block_hash: tx_hash("ee")
      )

    assert changed.downgrade_state == :downgraded
    assert restored.downgrade_state == :downgraded
    assert restored.verification_state == :unverified
    assert restored.verification_reason == "configuration_changed"
    assert restored.prior_verified_fingerprint == verified.configuration_fingerprint

    assert {:ok, immutable_verified} =
             Autolaunch.get_treasury_security_report(verified.id, actor: nil)

    assert immutable_verified.verification_state == :verified
    assert immutable_verified.downgrade_state == :none
  end

  test "PERMANENT_DOWNGRADE_IS_INDEPENDENT_OF_SOURCE_BLOCK_INSERTION_ORDER" do
    Client.install(block_number: 30_000_001, block_hash: tx_hash("ef"), threshold: 1)

    assert {:ok, changed_first} =
             Autolaunch.observe_treasury_security(@safe, %{}, actor: %System{})

    older_verified =
      Client.seed_verified!(@safe,
        block_number: 30_000_000,
        block_hash: tx_hash("ab")
      )

    restored =
      Client.seed_verified!(@safe,
        block_number: 30_000_002,
        block_hash: tx_hash("ee")
      )

    assert changed_first.downgrade_state == :none
    assert older_verified.downgrade_state == :downgraded
    assert older_verified.verification_state == :unverified
    assert restored.downgrade_state == :downgraded
    assert restored.verification_state == :unverified
    assert restored.prior_verified_fingerprint == older_verified.configuration_fingerprint

    assert {:ok, current} = Autolaunch.current_treasury_security(@safe, actor: nil)
    assert current.id == restored.id
    assert current.downgrade_state == :downgraded
  end

  test "ADDRESS_SCOPED_PERSISTENCE_ORDERS_CONCURRENT_VERIFIED_THEN_CHANGED_OBSERVATIONS" do
    clear_committed_reports()
    on_exit(&clear_committed_reports/0)

    Application.put_env(:autolaunch, :autolaunch_treasury_chain_client, ConcurrentClient)
    Application.put_env(:autolaunch, :test_treasury_observation_coordinator, self())

    evidence = %{usdc: tx_hash("11"), regent: tx_hash("22"), outbound: tx_hash("33")}

    verified_task =
      start_holding_observation(fn ->
        Autolaunch.observe_treasury_security(@concurrent_safe, evidence, actor: %System{})
      end)

    assert_receive {:treasury_observe, verified_caller, @concurrent_safe, verified_evidence},
                   5_000

    send(
      verified_caller,
      {:treasury_observation, observation(@concurrent_safe, verified_evidence)}
    )

    assert_receive {:holding_observation, holder, holder_backend}, 5_000
    holder = {verified_task, holder, holder_backend}

    changed =
      start_contending_observation(fn ->
        Autolaunch.observe_treasury_security(@concurrent_safe, %{}, actor: %System{})
      end)

    assert_receive {:treasury_observe, changed_caller, @concurrent_safe, changed_evidence}, 5_000

    send(
      changed_caller,
      {:treasury_observation,
       observation(@concurrent_safe, changed_evidence,
         block_number: 30_000_001,
         block_hash: tx_hash("ef"),
         threshold: 1
       )}
    )

    assert_blocked_by(changed, holder)

    assert {:ok, verified} = release_observation(holder)
    assert {:ok, downgraded} = settle_observation(changed)

    assert verified.verification_state == :verified
    assert downgraded.downgrade_state == :downgraded
    assert downgraded.verification_state == :unverified
    assert downgraded.verification_reason == "configuration_changed"
    assert downgraded.prior_verified_fingerprint == verified.configuration_fingerprint

    reports =
      unboxed(fn ->
        Autolaunch.list_treasury_security_reports(@concurrent_safe, actor: nil)
      end)

    assert {:ok, [current, original]} = reports
    assert current.id == downgraded.id
    assert current.downgrade_state == :downgraded
    assert original.id == verified.id
    assert original.verification_state == :verified
    assert original.downgrade_state == :none
  end

  defp observation(address, evidence, overrides \\ []) do
    observation = %{
      block: %{
        number: Keyword.get(overrides, :block_number, 30_000_000),
        hash: Keyword.get(overrides, :block_hash, tx_hash("ab"))
      },
      runtime_code: "0x6001600055",
      runtime_identity: tx_hash("44"),
      admitted_safe?: true,
      admitted_split?: false,
      safe_singleton: "0x41675c099f32341bf84bfc5382af534df5c7461a",
      safe_version: "1.4.1",
      owners: owners(),
      threshold: Keyword.get(overrides, :threshold, 2),
      modules: [],
      guard: "0x0000000000000000000000000000000000000000",
      fallback_handler: "0xfd0732dc9e303f09fcef3a7388ad10a83459ec99",
      fallback_admitted?: true,
      evidence: %{}
    }

    fingerprint = TreasurySecurity.fingerprint(address, observation)

    evidence =
      Map.new([:usdc, :regent, :outbound], fn key ->
        {key,
         if evidence[key] do
           %{
             verified: true,
             transaction_hash: evidence[key],
             receipt_block_number: 29_999_999,
             receipt_block_hash: tx_hash("cd"),
             log_index: 0,
             safe_address: address,
             historical_fingerprint: fingerprint,
             decoded: Atom.to_string(key)
           }
         end}
      end)

    %{observation | evidence: evidence}
  end

  defp start_holding_observation(attempt) do
    test = self()

    Task.async(fn -> unboxed(fn -> hold_observation(attempt, test) end) end)
  end

  defp hold_observation(attempt, test) do
    Repo.transaction(fn ->
      result = attempt.()
      send(test, {:holding_observation, self(), backend_pid()})

      receive do
        :release_observation -> result
      end
    end)
  end

  defp start_contending_observation(attempt) do
    test = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:contending_observation, backend_pid()})
          result = attempt.()
          send(test, {:settled_observation, result})
          result
        end)
      end)

    assert_receive {:contending_observation, backend}, 5_000
    {task, backend}
  end

  defp release_observation({task, holder, _backend}) do
    send(holder, :release_observation)
    {:ok, result} = Task.await(task, 15_000)
    result
  end

  defp settle_observation({task, _backend}) do
    assert_receive {:settled_observation, result}, 15_000
    assert Task.await(task, 15_000) == result
    result
  end

  defp assert_blocked_by({_task, contender}, {_holder_task, _holder, holder}) do
    assert Enum.reduce_while(1..2_000, false, fn _attempt, _blocked ->
             if holder in blocking_pids(contender), do: {:halt, true}, else: {:cont, false}
           end),
           "the changed observation never blocked on the address-scoped treasury lock"
  end

  defp blocking_pids(backend) do
    unboxed(fn ->
      %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
      blockers
    end)
  end

  defp backend_pid do
    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  defp clear_committed_reports do
    unboxed(fn ->
      # These rows commit outside the sandbox to prove two-connection ordering.
      # The resource has no destroy action, so cleanup bypasses Ash deliberately.
      Repo.delete_all(
        from(report in TreasurySecurityReport,
          where: report.address == ^@concurrent_safe
        )
      )
    end)
  end

  defp unboxed(attempt), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, attempt)

  defp owners do
    [
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
      "0x3333333333333333333333333333333333333333"
    ]
  end

  defp tx_hash(byte), do: "0x" <> String.duplicate(byte, 32)
end
