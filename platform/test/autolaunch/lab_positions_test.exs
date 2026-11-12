defmodule Autolaunch.LabPositionsTest do
  # After an auction ends, each of its unfinished site positions is read back
  # from the auction's own `bids(bidId)`. A finished bid is never read again; a
  # bid with a bad answer is skipped; a node that stops answering ends the pass.
  use Autolaunch.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Autolaunch.Actors.System
  alias Autolaunch.{BaseRpcStub, Bid, Lab, LabAbi, LabPositions, LabProjection, TestSupport}

  @auction "0xb2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  @owner "0x1515151515151515151515151515151515151515"
  @q96 79_228_162_514_264_337_593_543_950_336
  @block %{number: 500, hash: "0x" <> String.duplicate("6c", 32)}
  @market %{end_block: 400, claim_block: 600}

  test "a returned or claimed bid is not read from the chain again" do
    auction = TestSupport.project_auction(address: @auction, state: :graduated)

    for {id, status} <- [
          {"1", :active},
          {"2", :returned},
          {"3", :claimable},
          {"4", :claimed},
          {"5", :awaiting_claim},
          {"6", :returnable}
        ],
        do: position!(auction.id, id, status)

    assert {:ok, positions} = LabPositions.positions(auction.id)
    assert positions |> Enum.map(& &1.onchain_bid_id) |> Enum.sort() == ["1", "3", "5", "6"]
  end

  test "a bid whose answer is bad is skipped and the bids after it are still read" do
    {abi, positions} = ended_auction_positions()
    install(%{"2" => "0x"})

    {{:ok, readings}, _log} =
      with_log(fn -> LabPositions.read(abi, positions, @auction, @market, @block, []) end)

    assert read_ids(readings) == ["1", "3"]
    assert Enum.all?(readings, &(&1.status == :returnable))
  end

  test "a node that stops answering ends the bid reads, keeping those already read" do
    {abi, positions} = ended_auction_positions()
    install(%{"2" => :unavailable})

    {{:ok, readings}, _log} =
      with_log(fn -> LabPositions.read(abi, positions, @auction, @market, @block, []) end)

    assert read_ids(readings) == ["1"]
    # Bid 3 was never asked for.
    refute bid_id_asked?("3")
  end

  defp ended_auction_positions do
    auction = TestSupport.project_auction(address: @auction, state: :graduated)
    for id <- ["1", "2", "3"], do: position!(auction.id, id, :active)
    {:ok, positions} = LabPositions.positions(auction.id)
    {Lab.current!().abis["auction"], Enum.sort_by(positions, & &1.onchain_bid_id)}
  end

  # Every bid answers as one not yet exited, except the ones `answers` names.
  defp install(answers) do
    abi = Lab.current!().abis["auction"]

    BaseRpcStub.install(:wallet_http_client, fn %{data: data}, _state ->
      id = Enum.find(["1", "2", "3"], &(data == bids_call(abi, &1)))
      Map.get_lazy(answers, id, fn -> unexited_bid() end)
    end)
  end

  defp bid_id_asked?(id) do
    abi = Lab.current!().abis["auction"]

    Stream.repeatedly(fn ->
      receive do
        {:rpc, "eth_call", [%{data: data}, _block]} -> data
        {:rpc, _method, _params} -> nil
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.member?(bids_call(abi, id))
  end

  defp bids_call(abi, id), do: LabAbi.encode(abi, "bids(uint256)", [String.to_integer(id)])

  # start block, mps, exited block (none), max price, owner, amount, filled.
  defp unexited_bid do
    words = [100, 1, 0, @q96] |> Enum.map_join(&BaseRpcStub.hex_word/1)

    "0x" <>
      words <>
      BaseRpcStub.address_word(@owner) <> Enum.map_join([2 * @q96, 0], &BaseRpcStub.hex_word/1)
  end

  defp read_ids(readings),
    do: readings |> Enum.map(& &1.position.onchain_bid_id) |> Enum.sort()

  defp position!(auction_id, id, status) do
    Bid
    |> Ash.Changeset.for_create(
      :project_lab,
      %{
        bid_id: LabProjection.bid_identity(@auction, id),
        auction_id: auction_id,
        owner_address: @owner,
        amount: "2",
        max_price: "1",
        status: status,
        auction_address: @auction,
        onchain_bid_id: id
      },
      actor: %System{}
    )
    |> Ash.create!()
  end
end
