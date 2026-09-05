defmodule Autolaunch.Chain.ManifestTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.Abi

  @chain_manifest_path "contracts/chain-contracts.yaml"
  @treasury_evidence_path "contracts/treasury-security-evidence.yaml"
  # The bidder interface stays reviewed and digest-pinned while no bidder action
  # is admitted, so these are proved against the pinned ABI without admitting one.
  @bidder_actions %{
    "continuous_clearing_auction" => %{
      "submit_bid" => {"submitBid(uint256,uint128,address,uint256,bytes)", "0xa52c8728"}
    },
    "permit2" => %{
      "approve" => {"approve(address,address,uint160,uint48)", "0x87517c45"}
    },
    "quote_token_erc20" => %{
      "approve_exact" => {"approve(address,uint256)", "0x095ea7b3"}
    }
  }
  # Nothing is admitted for production preparation on this site.
  @admitted_actions []
  # The clean-V1 subject wallet interface stays reviewed and digest-pinned while
  # no subject action is admitted, so these are proved against the final C9 ABI
  # without admitting one.
  @retained_evidence_actions %{
    "subject_token_erc20" => %{
      "approve_exact" => {"approve(address,uint256)", "0x095ea7b3"}
    },
    "subject_splitter_v1" => %{
      "stake" => {"stake(uint256)", "0xa694fc3a"},
      "unstake" => {"unstake(uint256)", "0x2e17de78"},
      "claim" => {"claim(address)", "0x1e83409a"},
      "claim_all" => {"claimAll()", "0xd1058e59"}
    },
    "payment_receiver_v1" => %{
      "pay" => {"pay(address,uint256,bytes32)", "0x5e5571ac"},
      "sweep" => {"sweep(address,bytes32)", "0x8a738683"},
      "set_receiver_note" => {"setReceiverNote(bytes32)", "0xb1379b2f"}
    },
    # The final launch interface stays reviewed and digest-pinned while no launch
    # action is admitted for production preparation.
    "regent_erc20" => %{
      "approve_exact" => {"approve(address,uint256)", "0x095ea7b3"}
    },
    "regents_autolaunch_factory_v1" => %{
      "launch" =>
        {"launch((string,string,string,string,string,address,uint128,uint256))", "0xd0464e3e"}
    },
    "regent_lbp_strategy_v1" => %{}
  }
  # The one entry that pins a deployment rather than a prepared surface: the live
  # staking contract the REGENT page reads, which prepares nothing here.
  @deployment_pins %{"regent_revenue_staking" => %{}}

  # The final C9 source fingerprints. The upstream build artifacts these ABIs are
  # derived from are excluded by that repository's own .gitignore, so the durable
  # evidence is the compiler's metadata Keccak-256 of the exact source files,
  # alongside the runtime hashes its own pinned release manifest records.
  @c9_source_commit "5cf4a6b48388d54593b83230342542fee7c0f131"
  @c9_source_tree "33b80348eab6e7ba9bfd4947327a3710981d2092"
  @factory_source_keccak256 "0x0c09b28c782252ed8a99d68c027f7125c52c64410d6e4a03d018ff022c245c9a"
  @strategy_source_keccak256 "0x214e642ba5105763d7952909552f501800adb7e3887b67024afb797fa02ede01"
  @splitter_source_keccak256 "0xd411b2c4c69184ea684bfe63d118907c786fdad5a54cb3505488733161c58f4f"
  @c9_abi_surface_sha256 "8dc198f19bb55e76bcd6e81326a14203358717a9e74606bd280c8ce7be186e31"
  @c9_release_manifest_sha256 "a9ea436c3a66f4f296a4d9759be842ab77992578950cb23c2d8996d7b73c4c04"
  @c9_fork_observations_sha256 "198a4ab782db2bcec4b02e2594ad3c96133867e56a5ccbea6570d224c4597b7c"

  # The frozen-artifact runtime hashes each consumer contract must present, and
  # the SubjectSplitterV1 implementation hash the factory itself admits by code
  # hash, all read from that same release manifest.
  @runtime_keccak256 %{
    "regents_autolaunch_factory_v1" =>
      "0x38787efb5e28dc9d53e3e19a51ef7f83d02033e98e3414029df0f0841c06ff20",
    "regent_lbp_strategy_v1" =>
      "0x5ee28f1c96259ac3cb8134873cca3f24a07fa151bcc8818064a66480f2d59fb6",
    "subject_splitter_v1" => "0x4ba470d4c443ae5889f5e1f9095e07ed228853604762554437003ed115c56105",
    "payment_receiver_v1" => "0x96fa5c2a8dc2afb67752e6600a178c539661f93dc7615f4871f71bc8a24c6573"
  }

  # The permanent REGENT deployment and the live staking contract the REGENT page
  # reads, each pinned by address and by the digest of its deployed runtime.
  @regent_address "0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"
  @staking_address "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5"
  @usdc_address "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  # The exact six the strategy refuses as a launch treasury: three read at the
  # reviewed block, three frozen in the contract's own Base bindings.
  @frozen_refused_treasuries [
    %{"id" => "pool_manager", "address" => "0x498581fF718922c3f8e6A244956aF099B2652b2b"},
    %{"id" => "position_manager", "address" => "0x7C5f5A4bBd8fD63184577525326123B519429bDc"},
    %{"id" => "live_staking", "address" => "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5"}
  ]

  # Everything this consumer lane deliberately does not derive an encoder, action or admission
  # for. None of these may appear anywhere in the manifest or in either ABI file.
  @absent_consumer_surfaces ~w(
    setLaunchFee
    pauseLaunches
    unpauseLaunches
    createPaymentReceiver
    bindHook
    initializeDistribution
    migrate
  )

  # Every executable path and ABI file the superseded subject-payment lane needed.
  # None of them may exist anywhere in the manifest or on disk.
  @deleted_evidence ~w(payment_link_factory revenue_ingress_account revenue_share_splitter_v2)
  @deleted_abis ~w(
    abi/payment-link-factory.json
    abi/revenue-ingress-account.json
    abi/revenue-share-splitter-v2.json
  )
  @deleted_signatures [
    "createPaymentLink(bytes32,string,bytes32)",
    "createCanonicalPaymentLink(bytes32,string,bytes32)",
    "setPaymentLinkCanonical(address,bool)",
    "setPaymentLinkReceiverState(address,bool,address)",
    "sweepUSDC(bytes32)",
    "stake(uint256,address)",
    "unstake(uint256,address)",
    "claimUSDC(address)"
  ]

  test "every pinned ABI path and digest closes over the manifest" do
    pinned = for entry <- Map.values(evidence!()), entry["abi_path"], do: entry

    # Nine entries pin an ABI file; the staking entry pins a deployment instead.
    assert length(pinned) == 9

    for entry <- pinned do
      abi_path = Path.join("contracts", entry["abi_path"])
      assert File.regular?(abi_path)
      assert sha256(File.read!(abi_path)) == entry["abi_sha256"]
    end

    # A pinned deployment closes over its address and the digest of the runtime
    # code that address really carries.
    for {id, address} <- [
          {"regent_erc20", @regent_address},
          {"regent_revenue_staking", @staking_address}
        ] do
      entry = Map.fetch!(evidence!(), id)
      assert entry["address"] == address
      assert entry["runtime_code"]["bytes"] > 0
      assert entry["runtime_code"]["sha256"] =~ ~r/^[0-9a-f]{64}$/
      assert entry["runtime_code"]["keccak256"] =~ ~r/^0x[0-9a-f]{64}$/
    end

    # The staking deployment also pins the two token identities the page quotes
    # against, each with the read that proves it on chain.
    staking = Map.fetch!(evidence!(), "regent_revenue_staking")

    assert staking["onchain_constants"] == %{
             "stake_token" => @regent_address,
             "usdc" => @usdc_address
           }

    assert staking["reads"] == [
             %{"id" => "stake_token", "signature" => "stakeToken()", "selector" => "0x51ed6a30"},
             %{"id" => "usdc", "signature" => "usdc()", "selector" => "0x3e413bee"},
             %{"id" => "total_staked", "signature" => "totalStaked()", "selector" => "0x817b1cd2"}
           ]
  end

  test "pinned ABIs contain every prepared-action signature and selector" do
    evidence = evidence!()

    for actions <- [@bidder_actions, @retained_evidence_actions],
        {contract_id, expected_actions} <- actions,
        {action_id, {signature, selector}} <- expected_actions do
      entry = Map.fetch!(evidence, contract_id)
      assert action_id in entry["action_ids"]

      abi = "contracts" |> Path.join(entry["abi_path"]) |> File.read!() |> Jason.decode!()

      assert signature_present?(abi, signature)
      assert selector_for(signature) == selector
    end
  end

  test "declared chain validation closes over every evidence entry and admitted action" do
    admission = admission!()

    assert admission["validation_command"] == "mix test test/autolaunch/chain/manifest_test.exs"

    assert admission["autolaunch_consumer_freeze"] == %{
             "repository" => "autolaunch-contracts",
             "source_commit" => @c9_source_commit,
             "source_tree" => @c9_source_tree,
             "abi_surface_sha256" => @c9_abi_surface_sha256,
             "release_manifest_sha256" => @c9_release_manifest_sha256,
             "fork_observations_sha256" => @c9_fork_observations_sha256,
             "deployment_status" => "deployment_pending",
             "admission" => "disabled"
           }

    evidence = Map.new(admission["reviewed_action_evidence"], &{&1["contract_id"], &1})

    # Nothing is admitted for production preparation, so the closure over admitted
    # actions is the empty one and there is no action id to resolve.
    assert admission["admitted_prepared_actions"] == @admitted_actions

    for dotted <- @admitted_actions do
      [contract_id, action_id] = String.split(dotted, ".", parts: 2)
      assert action_id in Map.fetch!(evidence, contract_id)["action_ids"]
    end

    # Every evidence entry is accounted for by exactly one declared surface, so a
    # new entry cannot appear in the manifest without appearing here too.
    for {id, entry} <- evidence do
      expected_actions =
        Map.get(@bidder_actions, id) ||
          Map.get(@retained_evidence_actions, id) ||
          Map.fetch!(@deployment_pins, id)

      assert MapSet.new(entry["action_ids"] || []) == MapSet.new(Map.keys(expected_actions))
    end

    auction = Map.fetch!(evidence, "continuous_clearing_auction")
    assert auction["source_commit"] == "7d7602d257733315434570f2a0c2f94f1c7b207a"
    assert auction["interface_note"] =~ "canonical five-argument submitBid"
    assert auction["interface_note"] =~ "collects a non-native currency only through Permit2"
    refute auction["interface_note"] =~ "four-argument convenience overload"

    permit2 = Map.fetch!(evidence, "permit2")
    assert permit2["address"] == "0x000000000022D473030F116dDEE9F6B43aC78BA3"
    assert permit2["address_provenance"] =~ "2af06408b6a204824c2ecb245779ed400b535fb5"
    assert permit2["address_provenance"] =~ "src/utils/SafeTransferLib.sol line 64"

    # The retained consumer evidence is pinned to the exact final contract source
    # and to the runtime hash that build's own release manifest records.
    for {contract_id, runtime_keccak256} <- @runtime_keccak256 do
      entry = Map.fetch!(evidence, contract_id)
      assert entry["source_commit"] == @c9_source_commit
      assert entry["source_tree"] == @c9_source_tree
      assert entry["runtime_keccak256"] == runtime_keccak256
    end

    assert Map.fetch!(evidence, "subject_splitter_v1")["implementation_provenance"] =~
             @splitter_source_keccak256

    # The superseded lane leaves no evidence entry and no admitted action.
    for contract_id <- @deleted_evidence do
      refute Map.has_key?(evidence, contract_id)
    end
  end

  test "the superseded subject-payment ABI evidence is gone from the manifest and from disk" do
    manifest = File.read!(@chain_manifest_path)

    for contract_id <- @deleted_evidence do
      refute manifest =~ contract_id
    end

    for abi_path <- @deleted_abis do
      refute manifest =~ abi_path
      refute File.exists?(Path.join("contracts", abi_path))
    end

    # The subject lane's own ABI files declare none of the superseded shapes.
    for path <- [
          "contracts/abi/subject-splitter-v1.json",
          "contracts/abi/payment-receiver-v1.json"
        ],
        signature <- @deleted_signatures do
      abi = path |> File.read!() |> Jason.decode!()
      refute signature_present?(abi, signature), "#{path} still declares #{signature}"
    end
  end

  test "every retained C9 selector is an independent Foundry derivation of its declared signature" do
    chain_manifest = YamlElixir.read_from_file!(@chain_manifest_path)

    evidence =
      chain_manifest["contracts"]
      |> List.first()
      |> Map.fetch!("reviewed_action_evidence")
      |> Map.new(&{&1["contract_id"], &1})

    for {contract_id, actions} <-
          Map.take(@retained_evidence_actions, [
            "subject_splitter_v1",
            "payment_receiver_v1"
          ]),
        {action_id, {signature, selector}} <- actions do
      entry = Map.fetch!(evidence, contract_id)
      assert action_id in entry["action_ids"]

      abi = "contracts" |> Path.join(entry["abi_path"]) |> File.read!() |> Jason.decode!()
      assert signature_present?(abi, signature)
      assert selector_for(signature) == selector

      # And it is not admitted for production preparation.
      refute "#{contract_id}.#{action_id}" in @admitted_actions
    end
  end

  test "the final C9 launch evidence pins its source fingerprints and admits no production action" do
    evidence = evidence!()

    factory = Map.fetch!(evidence, "regents_autolaunch_factory_v1")
    strategy = Map.fetch!(evidence, "regent_lbp_strategy_v1")

    for entry <- [factory, strategy] do
      assert entry["source_commit"] == @c9_source_commit
      assert entry["source_tree"] == @c9_source_tree
      assert entry["artifact_provenance"] =~ ".gitignore excludes"
      assert entry["artifact_provenance"] =~ "not a tracked file"
    end

    assert factory["source_keccak256"] == @factory_source_keccak256
    assert strategy["source_keccak256"] == @strategy_source_keccak256
    assert factory["target"] == "c5_admitted_factory_address"
    assert strategy["target"] == "reviewed_factory_bound_strategy_address"
    assert strategy["action_ids"] == []

    # The factory admits the splitter implementation by exact runtime code hash,
    # so the consumer freeze records that binding alongside the factory's own.
    assert factory["factory_bound_splitter_runtime_keccak256"] ==
             @runtime_keccak256["subject_splitter_v1"]

    # The one strategy read this lane performs, and the three frozen identities
    # that complete the exact six a launch treasury may not be.
    assert strategy["reads"] == [
             %{"id" => "hook", "signature" => "hook()", "selector" => "0x7f5a7c7b"}
           ]

    assert strategy["refused_launch_treasuries"] == @frozen_refused_treasuries

    assert strategy["refused_launch_treasury_provenance"] =~
             "BaseBindings.sol lines 19, 20 and 21"

    # The exact allowance rule the fee correction follows, and no other spender.
    regent = Map.fetch!(evidence, "regent_erc20")
    assert regent["address"] == "0x6f89bcA4eA5931EdFCB09786267b251DeE752b07"
    assert regent["action_ids"] == ["approve_exact"]
    assert regent["interface_note"] =~ "exact current launch fee"
    assert regent["interface_note"] =~ "no unlimited approval"

    # Every final action id is reviewed evidence and none of them is admitted for
    # production preparation: deployment evidence must open that gate later.
    admitted = admission!()["admitted_prepared_actions"]
    assert admitted == @admitted_actions

    for contract_id <- ["regents_autolaunch_factory_v1", "regent_lbp_strategy_v1", "regent_erc20"],
        action_id <- Map.fetch!(evidence, contract_id)["action_ids"] do
      refute "#{contract_id}.#{action_id}" in admitted
    end
  end

  test "the launch tuple signature canonicalizes to the one literal the encoder holds" do
    entry = Map.fetch!(evidence!(), "regents_autolaunch_factory_v1")
    abi = "contracts" |> Path.join(entry["abi_path"]) |> File.read!() |> Jason.decode!()
    declared = Enum.find(abi, &(&1["name"] == "launch"))

    # The canonicalization is the manifest task's existing one, so the literal in
    # `LaunchAbi` is proved against a second implementation rather than itself.
    signature = Mix.Tasks.Autolaunch.VerifyChainManifest.canonical_signature(declared)

    assert signature == Autolaunch.Chain.LaunchAbi.signature(:launch)
    assert selector_for(signature) == Autolaunch.Chain.LaunchAbi.selector(:launch)
    assert selector_for(signature) == "0xd0464e3e"
  end

  test "no governance, receiver, construction or migration surface is derived by the consumer lane" do
    for path <- [
          "contracts/abi/regents-autolaunch-factory-v1.json",
          "contracts/abi/regent-lbp-strategy-v1.json"
        ] do
      abi = path |> File.read!() |> Jason.decode!()
      names = MapSet.new(abi, & &1["name"])

      for surface <- @absent_consumer_surfaces do
        refute MapSet.member?(names, surface), "#{path} still declares #{surface}"
      end
    end

    # Absent from the ABI files is not enough: no evidence entry anywhere in the
    # manifest may carry one as an action id either.
    declared =
      evidence!() |> Map.values() |> Enum.flat_map(&(&1["action_ids"] || [])) |> MapSet.new()

    for surface <- @absent_consumer_surfaces do
      refute MapSet.member?(declared, surface)
    end

    factory = Map.fetch!(evidence!(), "regents_autolaunch_factory_v1")
    assert factory["interface_note"] =~ "deliberately not derived"
    assert Map.fetch!(evidence!(), "regent_lbp_strategy_v1")["interface_note"] =~ "never reaches"
  end

  describe "PRODUCTION_STAYS_FAIL_CLOSED: the launch lane prepares nothing" do
    test "no admitted production action exists for this lane" do
      admitted =
        "contracts/chain-contracts.yaml"
        |> YamlElixir.read_from_file!()
        |> Map.fetch!("contracts")
        |> List.first()
        |> Map.fetch!("admitted_prepared_actions")

      for action <- admitted do
        refute String.starts_with?(action, "regents_autolaunch_factory")
        refute String.starts_with?(action, "regent_lbp_strategy")
        refute String.starts_with?(action, "regent_erc20")
      end
    end
  end

  describe "PRODUCTION_STAYS_FAIL_CLOSED: the subject wallet lane prepares nothing" do
    test "no admitted production action exists for this lane" do
      admitted =
        "contracts/chain-contracts.yaml"
        |> YamlElixir.read_from_file!()
        |> Map.fetch!("contracts")
        |> List.first()
        |> Map.fetch!("admitted_prepared_actions")

      for action <- admitted, do: refute(String.starts_with?(action, "subject_"))
      refute Enum.any?(admitted, &String.contains?(&1, "payment_receiver"))
    end
  end

  test "every hand-written selector is an independent Foundry derivation of its signature" do
    # The ERC-20 interface is declared in code rather than pinned by an ABI file,
    # and the manifest's reads are literals nothing else derives, so each one is
    # proved here against Keccak-256 of its own signature.
    interface = for entry <- Abi.erc20_interface(), do: {entry["signature"], entry["selector"]}

    reads =
      for entry <- Map.values(evidence!()),
          read <- entry["reads"] || [],
          do: {read["signature"], read["selector"]}

    assert length(interface) == 3
    assert length(reads) == 6

    for {signature, selector} <- interface ++ reads do
      assert selector_for(signature) == selector
    end
  end

  test "the two evidence files pin one REGENT address and one USDC address" do
    evidence = evidence!()
    tokens = @treasury_evidence_path |> YamlElixir.read_from_file!() |> Map.fetch!("tokens")

    regent = Map.fetch!(evidence, "regent_erc20")["address"]
    constants = Map.fetch!(evidence, "regent_revenue_staking")["onchain_constants"]

    # The treasury evidence writes both addresses lowercase and the chain manifest
    # writes them checksummed, so one site-wide identity is one case-insensitive
    # match across both files.
    assert String.downcase(regent) == Map.fetch!(tokens, "regent")
    assert String.downcase(Map.fetch!(constants, "stake_token")) == Map.fetch!(tokens, "regent")
    assert String.downcase(Map.fetch!(constants, "usdc")) == Map.fetch!(tokens, "usdc")
  end

  defp evidence!,
    do: Map.new(admission!()["reviewed_action_evidence"], &{&1["contract_id"], &1})

  defp admission!,
    do: @chain_manifest_path |> YamlElixir.read_from_file!() |> Map.fetch!("contracts") |> hd()

  # The canonicalization is the manifest task's, so a tuple argument closes over
  # its own components rather than over the word "tuple".
  defp signature_present?(abi, signature) do
    Enum.any?(abi, fn entry ->
      entry["type"] == "function" and
        Mix.Tasks.Autolaunch.VerifyChainManifest.canonical_signature(entry) == signature
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp selector_for(signature) do
    cast = System.find_executable("cast") || flunk("Foundry cast is required for chain checks")
    {selector, 0} = System.cmd(cast, ["sig", signature], stderr_to_stdout: true)
    String.trim(selector)
  end
end
