defmodule Autolaunch.Stocks.LaunchActionsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.Abi
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.LaunchActions

  @abi "../../../../contracts/abi/stocks-launchpad-v1.json"
       |> Path.expand(__DIR__)
       |> File.read!()
       |> Jason.decode!()

  # The standard ERC-20 surface the Stocks lab configuration declares for REGENT.
  @erc20 [
    %{
      "type" => "function",
      "name" => "approve",
      "stateMutability" => "nonpayable",
      "inputs" => [
        %{"name" => "spender", "type" => "address"},
        %{"name" => "amount", "type" => "uint256"}
      ],
      "outputs" => [%{"name" => "", "type" => "bool"}]
    }
  ]

  @config %{abis: %{"launchpad" => @abi, "erc20" => @erc20}}
  @stock "0xb200000000000000000000c2e324d24d7eecd1fb"
  @admin "0x4444444444444444444444444444444444444444"
  @splitter "0x5555555555555555555555555555555555555555"
  @launchpad "0x7777777777777777777777777777777777777777"
  @regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"
  @fee 100_000 * Integer.pow(10, 18)
  @q96 Integer.pow(2, 96)

  @fields %{
    name: "Apple Pair",
    symbol: "APLP",
    description: "A test launch",
    website: "https://example.com",
    image: "https://example.com/i.png",
    stock: @stock,
    stock_symbol: "AAPLc",
    start_at: ~U[2026-09-10 12:00:00Z],
    start_timezone: "Etc/UTC",
    # 1,234.56789012 AAPLc in 8 decimals: 123_456_789_012 base units.
    minimum_raise: "1234.56789012",
    # 1.25 AAPLc per NEW: 1.25e8 / 1e18 * 2^96 = 2^96 / 8e9, not a multiple of 100.
    floor_price: "1.25",
    fee_administrator: @admin,
    subject_splitter: @splitter
  }

  # The fork answered at 12:00 less 1,001 seconds, so the start is 501 blocks
  # away: ceil(1001 / 2). The signer holds the fee and has approved nothing yet.
  @snapshot %{
    launchpad: @launchpad,
    regent: @regent,
    paused: false,
    fee: @fee,
    balance: @fee,
    allowance: 0,
    admission: %{admitted: true, decimals: 8, route: "0x6666666666666666666666666666666666666666"},
    subject: :verified,
    block: %{
      number: 1_000_000,
      hash: "0x" <> String.duplicate("ab", 32),
      timestamp: DateTime.to_unix(~U[2026-09-10 12:00:00Z]) - 1_001
    }
  }

  # AT09: the exact tuple the launchpad executes for known inputs, and the exact
  # allowance rule in front of it.
  test "the launch calldata carries the snapped floor, the derived start block and exact units" do
    assert {:ok, executable} = LaunchActions.executable(@fields, @snapshot, @config)

    candidate = div(@q96, 8_000_000_000)
    assert rem(candidate, 100) != 0
    assert executable.floor_price_q96 == candidate - rem(candidate, 100)
    assert rem(executable.floor_price_q96, 100) == 0
    assert executable.floor_price_q96 >= Integer.pow(2, 32) + 1
    assert executable.floor_price_evidence.adjustment_required
    assert executable.tick_spacing_q96 == div(executable.floor_price_q96, 100)
    assert executable.start_block == 1_000_000 + 501
    assert executable.end_block == 1_000_000 + 501 + 43_200
    assert executable.required_stock_raised == 123_456_789_012
    assert executable.subject_splitter == @splitter
    assert executable.launch_fee == @fee

    data = LaunchActions.launch_data(@fields, executable, @config)

    signature =
      "launch((string,string,string,string,string,address,uint64,uint256,uint128,address,address,uint256))"

    assert String.starts_with?(data, LabAbi.selector(signature))
    {:ok, words} = LabAbi.decode_words("0x" <> String.slice(data, 10..-1//1))

    # One dynamic tuple: its offset, then the tuple head of twelve words.
    assert Enum.at(words, 0) == 32

    [
      name,
      symbol,
      description,
      website,
      image,
      stock,
      start_block,
      floor,
      required,
      admin,
      splitter,
      expected_fee
    ] =
      Enum.slice(words, 1, 12)

    assert [name, symbol, description, website, image] == [384, 448, 512, 576, 640]
    assert {:ok, @stock} == Abi.word_address(stock)
    assert start_block == 1_000_501
    assert floor == executable.floor_price_q96
    assert required == 123_456_789_012
    assert {:ok, @admin} == Abi.word_address(admin)
    assert {:ok, @splitter} == Abi.word_address(splitter)
    assert expected_fee == @fee

    # No allowance yet: the exact approval comes first, then the launch.
    assert [approval, launch] =
             LaunchActions.reviewed_steps(@fields, executable, @snapshot, @config)

    assert %{"step" => "launch", "to" => @launchpad, "data" => ^data} = launch

    assert %{"step" => "approval", "to" => @regent, "spender" => @launchpad, "data" => approve} =
             approval

    assert approval["amount"] == Integer.to_string(@fee)
    assert String.starts_with?(approve, LabAbi.selector("approve(address,uint256)"))
    {:ok, [spender, amount]} = LabAbi.decode_words("0x" <> String.slice(approve, 10..-1//1))
    assert {:ok, @launchpad} == Abi.word_address(spender)
    assert amount == @fee

    # An allowance that already equals the fee is spent as it stands.
    assert [^launch] =
             LaunchActions.reviewed_steps(
               @fields,
               executable,
               %{@snapshot | allowance: @fee},
               @config
             )

    # Any other allowance, higher included, is corrected to exactly the fee first.
    assert [^approval, ^launch] =
             LaunchActions.reviewed_steps(
               @fields,
               executable,
               %{@snapshot | allowance: @fee * 2},
               @config
             )

    # A wallet that holds less REGENT than the fee is refused before any review exists.
    assert {:error, %{reason: :insufficient_regent}} =
             LaunchActions.executable(@fields, %{@snapshot | balance: @fee - 1}, @config)

    assert LaunchActions.launch_fee_copy("100000") ==
             "100,000 REGENT, paid to REGENT staking as rewards, not refunded if the minimum is not raised"

    assert executable.floor_price_evidence.executable_stock_per_new ==
             Autolaunch.Stocks.Amounts.format_cca_price(executable.floor_price_q96, 8, 18)

    # Never above what was entered: the exact executable price reads back below 1.25.
    assert String.starts_with?(executable.floor_price_evidence.executable_stock_per_new, "1.2499")

    # The same derivation refuses what the launchpad would refuse.
    soon = %{
      @snapshot
      | block: %{@snapshot.block | timestamp: DateTime.to_unix(@fields.start_at) - 599}
    }

    assert {:error, %{reason: :start_too_soon}} = LaunchActions.executable(@fields, soon, @config)

    late = %{
      @snapshot
      | block: %{@snapshot.block | timestamp: DateTime.to_unix(@fields.start_at) - 31 * 86_400}
    }

    assert {:error, %{reason: :start_too_late}} = LaunchActions.executable(@fields, late, @config)

    assert {:error, %{reason: :floor_price_too_low}} =
             LaunchActions.executable(
               %{@fields | floor_price: "0.000000000000000001"},
               @snapshot,
               @config
             )

    assert {:error, %{reason: :amount_not_representable}} =
             LaunchActions.executable(
               %{@fields | minimum_raise: "1.000000001"},
               @snapshot,
               @config
             )
  end

  # AT06 / §5.1: switching the subject lane off leaves no splitter in the params.
  test "disabling the subject lane removes the splitter from the executable params" do
    draft_id = Ecto.UUID.generate()

    image = %Autolaunch.Stocks.LaunchDraftImage{
      id: Ecto.UUID.generate(),
      digest: String.duplicate("ab", 32),
      human_account_id: 1,
      stock_launch_draft_id: draft_id
    }

    draft = %{
      id: draft_id,
      human_account_id: 1,
      name: "Apple Pair",
      symbol: "APLP",
      description: "A test launch",
      website: "https://example.com",
      image: Autolaunch.Stocks.LaunchDraftImageStorage.public_url(image),
      stock_launch_draft_image_id: image.id,
      stock_launch_draft_image: image,
      stock_chain_id: 8453,
      stock_address: "0xb200000000000000000000C2e324d24d7eEcd1fb",
      start_at: ~U[2026-09-10 12:00:00Z],
      start_timezone: "Europe/Amsterdam",
      minimum_raise: "1000",
      floor_price: "1.25",
      fee_administrator: @admin,
      subject_enabled: true,
      subject_splitter: @splitter
    }

    assert {:ok, %{subject_splitter: @splitter}} = LaunchActions.launchable(draft)

    disabled = %{draft | subject_enabled: false}
    assert {:ok, %{subject_splitter: nil} = fields} = LaunchActions.launchable(disabled)

    assert {:ok, executable} =
             LaunchActions.executable(fields, %{@snapshot | subject: :off}, @config)

    assert executable.subject_splitter == "0x" <> String.duplicate("0", 40)

    {:ok, words} =
      LabAbi.decode_words(
        "0x" <> String.slice(LaunchActions.launch_data(fields, executable, @config), 10..-1//1)
      )

    assert Enum.at(words, 11) == 0

    refute String.contains?(
             LaunchActions.launch_data(fields, executable, @config),
             String.slice(@splitter, 2..-1//1)
           )
  end
end
