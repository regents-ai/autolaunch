defmodule Autolaunch.Stocks.LaunchActionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.Chain.Abi
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.LaunchActions

  @abi "../../../contracts/abi/stocks-launchpad-v2.json"
       |> Path.expand(__DIR__)
       |> File.read!()
       |> Jason.decode!()

  @config %{abis: %{"launchpad" => @abi}}
  @selectors ABI.parse_specification(@abi)
  @stock "0xb200000000000000000000c2e324d24d7eecd1fb"
  @launchpad "0x7777777777777777777777777777777777777777"

  @fields %{
    name: "Apple Pair",
    symbol: "APLP",
    description: "A test launch",
    website: "https://example.com",
    image: "https://example.com/i.png",
    stock: @stock,
    stock_symbol: "AAPLc"
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

  # REVIEW_SIGNS_ONLY_WHAT_WAS_REVIEWED: the review's one step is this calldata
  # (`review/6` saves `Review.step("launch", launchpad, launch_data(...))`), so the
  # step a person's wallet signs is the draft's own name, ticker, description,
  # website, picture and stock, for every draft the review admits, and nothing else.
  property "REVIEW_SIGNS_ONLY_WHAT_WAS_REVIEWED: the launch step decodes back to exactly the reviewed draft" do
    text = fn limit ->
      filter(string(:printable, max_length: limit), &(byte_size(&1) <= limit))
    end

    check all(
            name <- text.(64),
            symbol <- text.(16),
            description <- text.(512),
            website <- string(:printable, max_length: 200),
            image <- text.(256),
            stock <- binary(length: 20),
            max_runs: 200
          ) do
      fields = %{
        name: name,
        symbol: symbol,
        description: description,
        website: website,
        image: image,
        stock: "0x" <> Base.encode16(stock, case: :lower)
      }

      "0x" <> hex = LaunchActions.launch_data(fields, @config)

      # Read back through the launchpad's own ABI: the selector must be its launch.
      assert {%{function: "launch"}, [{^name, ^symbol, ^description, ^website, ^image, ^stock}]} =
               ABI.find_and_decode(@selectors, Base.decode16!(hex, case: :lower))
    end
  end

  # AT09: the exact tuple the launchpad executes.
  test "the launch calldata carries only what the creator chose" do
    assert {:ok, executable} = LaunchActions.executable(@fields, @snapshot, @config)

    # The auction's lowest floor, 2^32 + 1, rounded up onto the bid grid.
    assert executable.floor_price_q96 == 4_294_967_300
    assert executable.tick_spacing_q96 == 42_949_673
    # ceil(497,500,000e18 x floor / 2^96), the preset's REQUIRED_STOCK_RAISED.
    assert executable.required_stock_raised == 26_969_530
    assert executable.stock_decimals == 8

    data = LaunchActions.launch_data(@fields, @config)

    signature = "launch((string,string,string,string,string,address))"

    assert String.starts_with?(data, LabAbi.selector(signature))
    {:ok, words} = LabAbi.decode_words("0x" <> String.slice(data, 10..-1//1))

    # One dynamic tuple: its offset, then the tuple head of six words.
    assert Enum.at(words, 0) == 32

    [name, symbol, description, website, image, stock] = Enum.slice(words, 1, 6)

    assert [name, symbol, description, website, image] == [192, 256, 320, 384, 448]
    assert {:ok, @stock} == Abi.word_address(stock)

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
