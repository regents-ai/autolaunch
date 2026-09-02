defmodule Autolaunch.Contracts.ChainManifestTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @erc20_approve_abi_sha256 "c3b0ea0f4cb03cf09bee2ef0ea451c976bcfb13c658f5f6d37784699d567efec"
  @factory_abi_sha256 "1cd2fce9c969dea3f043d6478505ce4c6e1b8657208e1eed3bc3290a4999d1f4"
  @strategy_abi_sha256 "29205b15c3cd9f010a9b4b946463d281a4a059c6327c3eff73286784b537ea68"
  @c9_source_commit "5cf4a6b48388d54593b83230342542fee7c0f131"

  # The bidder ABI is derived from exact pinned source, so the shapes the
  # confirmation path decodes are proved against the file rather than assumed.
  test "the pinned auction ABI declares only the canonical bid interface" do
    abi =
      @root
      |> Path.join("contracts/abi/continuous-clearing-auction.json")
      |> File.read!()
      |> Jason.decode!()

    assert Enum.map(abi, &{&1["type"], &1["name"]}) == [
             {"function", "submitBid"},
             {"function", "currency"},
             {"event", "BidSubmitted"}
           ]

    [submit_bid, currency, event] = abi

    assert submit_bid["stateMutability"] == "payable"

    assert Enum.map(submit_bid["inputs"], &{&1["name"], &1["type"]}) == [
             {"maxPriceQ96", "uint256"},
             {"amount", "uint128"},
             {"owner", "address"},
             {"prevTickPriceQ96", "uint256"},
             {"hookData", "bytes"}
           ]

    assert submit_bid["notice"] =~ "src/interfaces/IContinuousClearingAuction.sol:136-142"
    assert submit_bid["notice"] =~ "collects a non-native currency only through Permit2"

    assert currency["stateMutability"] == "view"
    assert currency["inputs"] == []
    assert Enum.map(currency["outputs"], & &1["type"]) == ["address"]

    assert event["anonymous"] == false

    assert Enum.map(event["inputs"], &{&1["name"], &1["type"], &1["indexed"]}) == [
             {"id", "uint256", true},
             {"owner", "address", true},
             {"priceQ96", "uint256", false},
             {"amount", "uint128", false}
           ]
  end

  test "the pinned Permit2 ABI declares the exact allowance interface the auction needs" do
    abi =
      @root
      |> Path.join("contracts/abi/permit2.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.new(&{&1["name"], &1})

    assert Enum.map(abi["approve"]["inputs"], &{&1["name"], &1["type"]}) == [
             {"token", "address"},
             {"spender", "address"},
             {"amount", "uint160"},
             {"expiration", "uint48"}
           ]

    assert abi["approve"]["stateMutability"] == "nonpayable"
    assert abi["approve"]["outputs"] == []

    assert Enum.map(abi["allowance"]["inputs"], &{&1["name"], &1["type"]}) == [
             {"user", "address"},
             {"token", "address"},
             {"spender", "address"}
           ]

    assert Enum.map(abi["allowance"]["outputs"], &{&1["name"], &1["type"]}) == [
             {"amount", "uint160"},
             {"expiration", "uint48"},
             {"nonce", "uint48"}
           ]

    # A zero expiration lasts only the current block, so the encoder refuses one.
    assert_raise FunctionClauseError, fn ->
      Autolaunch.Chain.Permit2Abi.encode_approve(
        "0x1111111111111111111111111111111111111111",
        "0x2222222222222222222222222222222222222222",
        1,
        0
      )
    end
  end

  # The final C9 ABI is derived from exact pinned source, so the shapes this lane
  # encodes and decodes are proved against the file rather than assumed.
  test "the final C9 splitter ABI declares exactly the caller-only customer surface" do
    abi = consumer_abi("subject-splitter-v1.json")

    assert Enum.map(abi, &{&1["type"], &1["name"]}) == [
             {"function", "stake"},
             {"function", "unstake"},
             {"function", "claim"},
             {"function", "claimAll"},
             {"function", "subject"},
             {"function", "usdc"},
             {"function", "regent"},
             {"function", "treasury"},
             {"function", "totalStaked"},
             {"function", "stakedOf"},
             {"function", "claimable"},
             {"event", "Staked"},
             {"event", "Unstaked"},
             {"event", "Claimed"}
           ]

    by_name = Map.new(abi, &{&1["name"], &1})

    # Every customer call takes its caller's own position and nothing else.
    for name <- ["stake", "unstake"] do
      assert by_name[name]["stateMutability"] == "nonpayable"
      assert Enum.map(by_name[name]["inputs"], & &1["type"]) == ["uint256"]
      assert by_name[name]["outputs"] == []
    end

    assert Enum.map(by_name["claim"]["inputs"], & &1["type"]) == ["address"]
    assert by_name["claimAll"]["inputs"] == []

    assert Enum.map(by_name["claimable"]["inputs"], & &1["type"]) == ["address", "address"]
    assert by_name["claimable"]["stateMutability"] == "view"

    assert Enum.map(by_name["Claimed"]["inputs"], &{&1["name"], &1["type"], &1["indexed"]}) == [
             {"account", "address", true},
             {"token", "address", true},
             {"amount", "uint256", false}
           ]

    for name <- ["Staked", "Unstaked"] do
      assert by_name[name]["anonymous"] == false

      assert Enum.map(by_name[name]["inputs"], &{&1["type"], &1["indexed"]}) == [
               {"address", true},
               {"uint256", false}
             ]
    end

    for entry <- abi, do: assert(entry["notice"] =~ @c9_source_commit)
  end

  test "the final C9 receiver ABI declares exactly the payment surface and its two events" do
    abi = consumer_abi("payment-receiver-v1.json")

    assert Enum.map(abi, &{&1["type"], &1["name"]}) ==
             [
               {"function", "pay"},
               {"function", "sweep"},
               {"function", "setReceiverNote"},
               {"function", "splitter"},
               {"function", "beneficiary"},
               {"function", "referralBps"},
               {"function", "noteEditor"},
               {"function", "receiverNote"},
               {"function", "subject"},
               {"function", "usdc"},
               {"function", "regent"},
               {"function", "treasury"}
             ] ++ [{"event", "PaymentRouted"}, {"event", "ReceiverNoteUpdated"}]

    by_name = Map.new(abi, &{&1["name"], &1})

    assert Enum.map(by_name["pay"]["inputs"], & &1["type"]) == ["address", "uint256", "bytes32"]
    assert Enum.map(by_name["sweep"]["inputs"], & &1["type"]) == ["address", "bytes32"]
    assert Enum.map(by_name["setReceiverNote"]["inputs"], & &1["type"]) == ["bytes32"]
    assert by_name["referralBps"]["stateMutability"] == "view"
    assert Enum.map(by_name["referralBps"]["outputs"], & &1["type"]) == ["uint16"]

    # The route event carries the actual gross, referral and net in its data, so a
    # sweep learns the amount it really moved.
    assert Enum.map(by_name["PaymentRouted"]["inputs"], &{&1["name"], &1["type"], &1["indexed"]}) ==
             [
               {"paymentRef", "bytes32", true},
               {"receiverNote", "bytes32", true},
               {"token", "address", true},
               {"gross", "uint256", false},
               {"referral", "uint256", false},
               {"net", "uint256", false}
             ]

    # Neither note field is indexed, so both ride in the data words.
    assert Enum.map(
             by_name["ReceiverNoteUpdated"]["inputs"],
             &{&1["name"], &1["type"], &1["indexed"]}
           ) == [{"previousNote", "bytes32", false}, {"newNote", "bytes32", false}]

    for entry <- abi, do: assert(entry["notice"] =~ @c9_source_commit)
  end

  # The final C9 ABI is derived from exact pinned source, so the shapes this lane
  # encodes and decodes are proved against the file rather than assumed.
  test "the final C9 factory ABI declares exactly the one customer call and its review reads" do
    abi = consumer_abi("regents-autolaunch-factory-v1.json")

    assert Enum.map(abi, &{&1["type"], &1["name"]}) == [
             {"function", "launch"},
             {"function", "launchFee"},
             {"function", "launchesPaused"},
             {"function", "strategy"},
             {"function", "launches"},
             {"function", "launchIdOfSubject"},
             {"event", "LaunchCreated"},
             {"event", "LaunchFeeCollected"}
           ]

    by_name = Map.new(abi, &{&1["name"], &1})

    # The launcher supplies one tuple and nothing else: no start block, floor
    # price, hook, pool setting, salt, supply, allocation or schedule.
    assert [%{"type" => "tuple"}] = by_name["launch"]["inputs"]
    assert by_name["launch"]["stateMutability"] == "nonpayable"

    # Reads are reads and the approval is a mutation; nothing here blurs them.
    for name <- ["launchFee", "launchesPaused", "strategy", "launches", "launchIdOfSubject"] do
      assert by_name[name]["stateMutability"] == "view"
    end

    assert [%{"type" => "tuple", "components" => record}] = by_name["launches"]["outputs"]
    assert Enum.map(record, & &1["type"]) == List.duplicate("address", 5)

    # Three indexed identities, then the treasury, the raise and the fixed
    # schedule in exactly the data words the decoder reads positionally.
    assert Enum.count(by_name["LaunchCreated"]["inputs"], & &1["indexed"]) == 3

    assert by_name["LaunchCreated"]["inputs"]
           |> Enum.drop(3)
           |> Enum.map(&{&1["name"], &1["type"], &1["indexed"]}) == [
             {"auction", "address", false},
             {"escrow", "address", false},
             {"treasury", "address", false},
             {"requiredRegentRaised", "uint128", false},
             {"startBlock", "uint64", false},
             {"endBlock", "uint64", false}
           ]

    assert Enum.map(
             by_name["LaunchFeeCollected"]["inputs"],
             &{&1["name"], &1["type"], &1["indexed"]}
           ) == [
             {"launchId", "uint256", true},
             {"payer", "address", true},
             {"regentSafe", "address", false},
             {"amount", "uint256", false}
           ]

    for entry <- abi, do: assert(entry["notice"] =~ @c9_source_commit)
  end

  test "the final C9 strategy ABI declares only its two identities and the frozen terms" do
    abi = consumer_abi("regent-lbp-strategy-v1.json")

    assert Enum.map(abi, & &1["name"]) == [
             "factory",
             "hook",
             "START_DELAY_BLOCKS",
             "AUCTION_DURATION_BLOCKS",
             "CLAIM_DELAY_BLOCKS",
             "MIGRATION_DELAY_BLOCKS",
             "FLOOR_PRICE_Q96",
             "BID_TICK_Q96",
             "AUCTION_ALLOCATION",
             "RESERVE_ALLOCATION",
             "PENDING_ALLOCATION",
             "POOL_FEE",
             "POOL_TICK_SPACING",
             "MAX_REACHABLE_RAISE"
           ]

    by_name = Map.new(abi, &{&1["name"], &1})

    # Every term is a read with no argument, so none of them can be chosen.
    for entry <- abi do
      assert entry["type"] == "function"
      assert entry["stateMutability"] == "view"
      assert entry["inputs"] == []
      assert entry["notice"] =~ @c9_source_commit
    end

    # The read that supplies one of the exact six refused launch treasuries.
    assert by_name["hook"]["notice"] =~ "refuse it, the factory and this strategy as a launch"

    # The one signed term, and the one whose word therefore needs bringing back.
    assert Enum.map(by_name["POOL_TICK_SPACING"]["outputs"], & &1["type"]) == ["int24"]
    assert by_name["POOL_TICK_SPACING"]["notice"] =~ "sign-extended"
    assert Enum.map(by_name["MAX_REACHABLE_RAISE"]["outputs"], & &1["type"]) == ["uint128"]
    assert Enum.map(by_name["POOL_FEE"]["outputs"], & &1["type"]) == ["uint24"]
  end

  test "final C9 evidence is digest-pinned and admitted for nothing in production" do
    admission = admission!()
    evidence = Map.new(admission["reviewed_action_evidence"], &{&1["contract_id"], &1})

    for {contract_id, digest} <- [
          {"regents_autolaunch_factory_v1", @factory_abi_sha256},
          {"regent_lbp_strategy_v1", @strategy_abi_sha256},
          {"regent_erc20", @erc20_approve_abi_sha256}
        ] do
      entry = Map.fetch!(evidence, contract_id)
      path = Path.join([@root, "contracts", entry["abi_path"]])

      assert File.regular?(path)
      assert entry["abi_sha256"] == digest
      assert Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) == digest

      for action_id <- entry["action_ids"] do
        refute "#{contract_id}.#{action_id}" in admission["admitted_prepared_actions"]
      end
    end

    # Both launch evidence topics are independent Keccak-256 derivations.
    factory = Map.fetch!(evidence, "regents_autolaunch_factory_v1")

    assert factory["confirmation_event_signatures"] == [
             Autolaunch.Chain.LaunchAbi.signature(:launch_created),
             Autolaunch.Chain.LaunchAbi.signature(:launch_fee_collected)
           ]

    for signature <- factory["confirmation_event_signatures"] do
      assert keccak(signature) ==
               Autolaunch.Chain.LaunchAbi.selector(launch_event_id(signature))
    end
  end

  defp launch_event_id("LaunchCreated" <> _rest), do: :launch_created
  defp launch_event_id("LaunchFeeCollected" <> _rest), do: :launch_fee_collected

  defp admission!,
    do:
      @root
      |> Path.join("contracts/chain-contracts.yaml")
      |> YamlElixir.read_from_file!()
      |> Map.fetch!("contracts")
      |> List.first()

  defp consumer_abi(file),
    do: @root |> Path.join("contracts/abi") |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp keccak(signature) do
    cast = System.find_executable("cast") || flunk("Foundry cast is required for chain checks")
    {topic, 0} = System.cmd(cast, ["keccak", signature], stderr_to_stdout: true)
    String.trim(topic)
  end
end
