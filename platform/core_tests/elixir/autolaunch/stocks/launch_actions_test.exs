defmodule Autolaunch.Stocks.LaunchActionsTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.Abi
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.LaunchActions

  @abi "../../../../contracts/abi/stocks-launchpad-v1.json"
       |> Path.expand(__DIR__)
       |> File.read!()
       |> Jason.decode!()

  @config %{abis: %{"launchpad" => @abi}}
  @stock "0xb200000000000000000000c2e324d24d7eecd1fb"
  @launchpad "0x7777777777777777777777777777777777777777"
  @q96 Integer.pow(2, 96)

  @fields %{
    name: "Apple Pair",
    symbol: "APLP",
    description: "A test launch",
    website: "https://example.com",
    image: "https://example.com/i.png",
    stock: @stock,
    stock_symbol: "AAPLc",
    # 4.5 AAPLc, entered by the creator; AAPLc has 8 decimals.
    required_raise: "4.5",
    # 1.25 AAPLc per NEW: 1.25e8 / 1e18 * 2^96 = 2^96 / 8e9, not a multiple of 100.
    floor_price: "1.25"
  }

  @snapshot %{
    launchpad: @launchpad,
    hook: "0x6666666666666666666666666666666666666666",
    paused: false,
    admission: %{
      admitted: true,
      decimals: 8,
      route: "0x6666666666666666666666666666666666666666"
    },
    block: %{number: 1_000_000, hash: "0x" <> String.duplicate("ab", 32)}
  }

  # AT09: the exact tuple the launchpad executes for known inputs.
  test "the launch calldata carries the snapped floor and the creator's exact required raise" do
    assert {:ok, executable} = LaunchActions.executable(@fields, @snapshot, @config)

    candidate = div(@q96, 8_000_000_000)
    assert rem(candidate, 100) != 0
    assert executable.floor_price_q96 == candidate - rem(candidate, 100)
    assert rem(executable.floor_price_q96, 100) == 0
    assert executable.floor_price_q96 >= Integer.pow(2, 32) + 1
    assert executable.floor_price_evidence.adjustment_required
    assert executable.tick_spacing_q96 == div(executable.floor_price_q96, 100)
    assert executable.required_stock_raised == 450_000_000
    assert executable.stock_decimals == 8

    data = LaunchActions.launch_data(@fields, executable, @config)

    signature = "launch((string,string,string,string,string,address,uint256,uint128))"

    assert String.starts_with?(data, LabAbi.selector(signature))
    {:ok, words} = LabAbi.decode_words("0x" <> String.slice(data, 10..-1//1))

    # One dynamic tuple: its offset, then the tuple head of eight words.
    assert Enum.at(words, 0) == 32

    [name, symbol, description, website, image, stock, floor, required] =
      Enum.slice(words, 1, 8)

    assert [name, symbol, description, website, image] == [256, 320, 384, 448, 512]
    assert {:ok, @stock} == Abi.word_address(stock)
    assert floor == executable.floor_price_q96
    assert required == 450_000_000

    # No fee and no allowance: the launch is the only step.
    assert [%{"step" => "launch", "to" => @launchpad, "data" => ^data}] =
             LaunchActions.reviewed_steps(@fields, executable, @snapshot, @config)

    assert executable.floor_price_evidence.executable_stock_per_new ==
             Autolaunch.Stocks.Amounts.format_cca_price(executable.floor_price_q96, 8, 18)

    # Never above what was entered: the exact executable price reads back below 1.25.
    assert String.starts_with?(executable.floor_price_evidence.executable_stock_per_new, "1.2499")

    # The same derivation refuses what the launchpad would refuse.
    assert {:error, %{reason: :floor_price_too_low}} =
             LaunchActions.executable(
               %{@fields | floor_price: "0.000000000000000001"},
               @snapshot,
               @config
             )

    # A raise of nothing, one the stock cannot represent, or one beyond a uint128.
    assert {:error, %{reason: :required_raise_invalid}} =
             LaunchActions.executable(%{@fields | required_raise: "0"}, @snapshot, @config)

    assert {:error, %{reason: :required_raise_invalid}} =
             LaunchActions.executable(
               %{@fields | required_raise: "0.000000001"},
               @snapshot,
               @config
             )

    assert {:error, %{reason: :required_raise_invalid}} =
             LaunchActions.executable(
               %{@fields | required_raise: Integer.to_string(Integer.pow(2, 128))},
               @snapshot,
               @config
             )

    assert {:error, %{reason: :launches_paused}} =
             LaunchActions.executable(@fields, %{@snapshot | paused: true}, @config)

    assert {:error, %{reason: :stock_not_admitted}} =
             LaunchActions.executable(
               @fields,
               %{@snapshot | admission: %{@snapshot.admission | admitted: false}},
               @config
             )
  end
end
