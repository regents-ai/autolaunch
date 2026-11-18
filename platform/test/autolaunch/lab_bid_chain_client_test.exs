defmodule Autolaunch.LabBidChainClientTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, LabAbi, LabBidChainClient}

  @moduletag :capture_log

  @signer "0x" <> String.duplicate("11", 20)
  @auction "0x" <> String.duplicate("22", 20)

  # An auction from block 200 to 400, with a tick at every whole price from
  # the floor (1) to 700, and Base's latest block at `head` (300 unless a test
  # says otherwise), each head with its own hash. Open, it clears at 400, and a
  # bid's tick walk starts at the lowest price above that, so the 400 prices
  # below it are never read. Before its start it refuses `checkpoint()`, as the
  # auction does, and its stored clearing price is the floor. A call named in
  # `failing` is refused by the node. Each read of the auction's state tells the
  # test which block it named (`{:read_at, method, tag}`).
  defmodule AuctionStub do
    @spacing 2 ** 96
    @last_tick 2 ** 256 - 1
    @start 200

    def install(head \\ 300, failing \\ []) do
      previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
      Application.put_env(:autolaunch, :autolaunch_lab_http_client, __MODULE__)

      Application.put_env(:autolaunch, __MODULE__, %{
        head: head,
        failing: Enum.map(failing, &LabAbi.selector/1),
        test: self()
      })

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:autolaunch, __MODULE__)

        if previous,
          do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
          else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
      end)
    end

    def price(whole), do: whole * @spacing

    @doc "The hash of the head at block `number`."
    def hash(number),
      do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(number, 16)), 64, "0")

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      chain = Application.fetch_env!(:autolaunch, __MODULE__)

      with true <- method in ["eth_call", "eth_getCode"],
           [_target, tag] <- params,
           do: send(chain.test, {:read_at, method, tag})

      case answer(method, params, chain) do
        :reverted ->
          {:ok, %{status: 200, body: %{"error" => %{"message" => "execution reverted"}}}}

        result ->
          {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params, _chain), do: "0x2105"

    defp answer("eth_getBlockByNumber", _params, %{head: head}),
      do: %{
        "number" => "0x" <> Integer.to_string(head, 16),
        "hash" => hash(head),
        "timestamp" => "0x6700"
      }

    defp answer("eth_getCode", _params, _chain), do: "0x6080"

    defp answer(
           "eth_call",
           [%{data: "0x" <> <<selector::binary-size(8), argument::binary>>}, _],
           %{head: head, failing: failing}
         ) do
      cond do
        ("0x" <> selector) in failing ->
          :reverted

        "0x" <> selector == LabAbi.selector("ticks(uint256)") ->
          words([next_tick(String.to_integer(argument, 16)), 1])

        "0x" <> selector == LabAbi.selector("checkpoint()") and head < @start ->
          :reverted

        true ->
          words(Map.fetch!(fixed(), "0x" <> selector))
      end
    end

    defp words(words), do: "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)

    # Every whole price from 1 to 700 is a tick; 700 is the highest.
    defp next_tick(price) do
      whole = div(price, @spacing)

      cond do
        rem(price, @spacing) != 0 or whole not in 1..700 -> 0
        whole == 700 -> @last_tick
        true -> price + @spacing
      end
    end

    defp fixed do
      %{
        LabAbi.selector("currency()") => [0x3333333333333333333333333333333333333333],
        LabAbi.selector("balanceOf(address)") => [10 ** 18],
        LabAbi.selector("allowance(address,address)") => [0],
        LabAbi.selector("allowance(address,address,address)") => [0, 0, 0],
        LabAbi.selector("tickSpacing()") => [@spacing],
        LabAbi.selector("floorPrice()") => [@spacing],
        LabAbi.selector("startBlock()") => [@start],
        LabAbi.selector("endBlock()") => [400],
        LabAbi.selector("checkpoint()") => [price(400), 0, 0, 0, 0, 2 ** 64 - 1],
        LabAbi.selector("clearingPrice()") => [@spacing],
        LabAbi.selector("MAX_BID_PRICE()") => [price(10_000)],
        LabAbi.selector("nextActiveTickPrice()") => [price(401)]
      }
    end
  end

  # The auction takes a bid from its start block on (`_onlyActiveAuction`), and a
  # step prepared at the latest block lands in the next one at the earliest.
  test "two blocks before a Base auction's start a bid is not open, not unreadable: it cannot land in time" do
    AuctionStub.install(198)

    assert {:error, :bid_preparation_unavailable} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })
  end

  test "the block before a Base auction's start a bid is read at the floor, since it lands in the start block at the earliest" do
    AuctionStub.install(199)

    assert {:ok, %{clearing_price_q96: clearing, block: %{number: 199}, end_block: 400}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })

    assert clearing == AuctionStub.price(1)
    assert_read_at(199)
  end

  test "a bid in a busy auction names the tick just below its price, however many lie below" do
    AuctionStub.install()

    # The auction's own end block comes with the block the snapshot read.
    assert {:ok, %{prev_tick_price_q96: hint, end_block: 400, block: %{number: 300}}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })

    assert hint == AuctionStub.price(649)
    assert_read_at(300)
  end

  test "an auction whose end block cannot be read gives no snapshot: Base could not be read" do
    AuctionStub.install(300, ["endBlock()"])

    assert {:error, :chain_unavailable} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(650)
             })
  end

  test "a bid further up than one walk reaches names the highest tick the walk reached" do
    AuctionStub.install()

    assert {:ok, %{prev_tick_price_q96: hint}} =
             LabBidChainClient.snapshot(%{
               auction: @auction,
               signer: @signer,
               max_price_q96: AuctionStub.price(690)
             })

    assert hint == AuctionStub.price(401 + Autolaunch.Chain.CcaLists.reads())
  end

  # Every read the snapshot pinned to a block named the head at `number`, by
  # its hash, and refused an answer from a block no longer on the chain.
  defp assert_read_at(number) do
    tags = read_tags()
    assert Enum.any?(tags, &match?({"eth_call", _tag}, &1))

    assert tags |> Enum.map(&elem(&1, 1)) |> Enum.uniq() ==
             [%{blockHash: AuctionStub.hash(number), requireCanonical: true}]
  end

  defp read_tags do
    receive do
      {:read_at, method, tag} -> [{method, tag} | read_tags()]
    after
      0 -> []
    end
  end
end
