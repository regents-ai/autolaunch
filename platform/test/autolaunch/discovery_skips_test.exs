defmodule Autolaunch.DiscoverySkipsTest do
  @moduledoc """
  A launch the chain will not answer for does not hold up the launches after
  it, nor the other launchpad read in the same run. Both discoveries (the
  launches the site lists, and the launches the finisher knows of) record the
  rest, fail the run so it is tried again, and record the one left out once
  the chain answers for it.
  """

  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.{AuctionFinish, BaseRpcStub, Lab, LabAbi, LaunchDiscovery}
  alias Autolaunch.LaunchDiscovery.Discover
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @actor %System{}
  @hash "0x" <> String.duplicate("4c", 32)
  @launcher "0x1111111111111111111111111111111111111111"
  @start_block 30_001_800
  @migration_block 90
  @running 1

  setup do
    factory = Lab.address!(Lab.current!(), :factory)
    memestock = StocksLab.address!(StocksLab.current!(), :launchpad)

    BaseRpcStub.install(:autolaunch_lab_http_client, &answer/2)

    BaseRpcStub.put(%{
      blocks: %{
        "latest" => %{
          "number" => "0x1c9caf0",
          "hash" => BaseRpcStub.safe_hash(),
          "timestamp" => "0x6700"
        }
      },
      memestock: memestock,
      logs: [%{"transactionHash" => @hash}],
      unanswered: [1]
    })

    %{factory: factory, memestock: memestock}
  end

  # DISCOVERY_SKIPS_ONE_UNREADABLE_LAUNCH (audit finding B8, 12 Nov 2026).
  test "DISCOVERY_SKIPS_ONE_UNREADABLE_LAUNCH: listing discovery records the launches around one the chain will not answer for",
       %{factory: factory, memestock: memestock} do
    assert {:error, _left_out} = discover(LaunchDiscovery)

    assert recorded(LaunchDiscovery) == [{factory, 2}, {memestock, 1}] |> Enum.sort()

    # The count the pages read still shows the site behind the launchpad.
    revstake = Enum.find(Discover.launchpads(), &(&1.contract == factory))
    assert {:ok, %{made: 2, recorded: 1, missing: [1]}} = Discover.standing(revstake)

    BaseRpcStub.put(%{unanswered: []})
    assert :ok = discover(LaunchDiscovery)

    assert recorded(LaunchDiscovery) ==
             [{factory, 1}, {factory, 2}, {memestock, 1}] |> Enum.sort()

    assert {:ok, %{made: 2, recorded: 2, missing: []}} = Discover.standing(revstake)
  end

  test "the finisher's discovery records the launches around one the chain will not answer for",
       %{factory: factory, memestock: memestock} do
    assert {:error, _left_out} = discover(AuctionFinish)

    assert recorded(AuctionFinish) == [{factory, 2}, {memestock, 1}] |> Enum.sort()

    BaseRpcStub.put(%{unanswered: []})
    assert :ok = discover(AuctionFinish)

    assert recorded(AuctionFinish) == [{factory, 1}, {factory, 2}, {memestock, 1}] |> Enum.sort()
  end

  defp discover(resource) do
    resource
    |> Ash.ActionInput.for_action(:discover, %{}, actor: @actor)
    |> Ash.run_action()
  end

  defp recorded(resource) do
    resource
    |> Ash.read!(actor: @actor)
    |> Enum.map(&{&1.contract, &1.launch_id})
    |> Enum.sort()
  end

  # The Revstake factory has made two launches and the Memestock launchpad
  # one, all running. The factory does not answer for the launches named in
  # `unanswered`.
  defp answer(%{to: to, data: data}, state) do
    selector = String.slice(data, 0, 10)

    case if(to == state.memestock, do: memestock(selector), else: revstake(selector, data, state)) do
      :unavailable -> :unavailable
      words -> "0x" <> Enum.join(words)
    end
  end

  defp memestock(selector) do
    if selector == LabAbi.selector("nextLaunchId()") do
      [BaseRpcStub.hex_word(2)]
    else
      List.duplicate(0, StocksLabAbi.launch_record_words())
      |> List.replace_at(5, @start_block)
      |> List.replace_at(8, @migration_block)
      |> List.replace_at(9, @running)
      |> Enum.map(&BaseRpcStub.hex_word/1)
      |> List.replace_at(0, BaseRpcStub.address_word(@launcher))
      |> List.replace_at(3, BaseRpcStub.address_word(auction(9)))
    end
  end

  # The factory's count and launches, and the strategy's record of an auction.
  defp revstake(selector, data, state) do
    cond do
      selector == LabAbi.selector("nextLaunchId()") ->
        [BaseRpcStub.hex_word(3)]

      selector == LabAbi.selector("launches(uint256)") ->
        launch(data |> String.slice(10, 64) |> String.to_integer(16), state)

      selector == LabAbi.selector("distribution(address)") ->
        List.duplicate(0, LabAbi.distribution_words())
        |> List.replace_at(0, @running)
        |> List.replace_at(1, @start_block)
        |> List.replace_at(4, @migration_block)
        |> Enum.map(&BaseRpcStub.hex_word/1)

      selector == LabAbi.selector("START_DELAY_BLOCKS()") ->
        [BaseRpcStub.hex_word(300)]
    end
  end

  defp launch(launch_id, state) do
    if launch_id in state.unanswered,
      do: :unavailable,
      else:
        Enum.map(
          [@launcher, auction(7), auction(launch_id), auction(8), auction(6)],
          &BaseRpcStub.address_word/1
        )
  end

  defp auction(number), do: "0x" <> String.duplicate(Integer.to_string(number), 40)
end
