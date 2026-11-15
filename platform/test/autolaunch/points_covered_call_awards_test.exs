defmodule Autolaunch.PointsCoveredCallAwardsTest do
  # A covered call that changes hands, saved by the covered-calls reader
  # (Autolaunch.CoveredCalls.Sales), offers Regent Points First Autolaunch covered call
  # for its seller and for its buyer in the same transaction, and the site's own check
  # (Autolaunch.Points.CoveredCall) answers from the saved row. The reader reads a
  # scripted Base chain: the market's contract deployed at block 100, its sales in
  # block 120, the head there, and its listings and bids as Autolaunch.CoveredCallsChain
  # holds them.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo
  import Autolaunch.PointsTesting
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Autolaunch.{Accounts, BaseRpcStub, CoveredCallsChain, Release}
  alias Autolaunch.Actors.System
  alias Autolaunch.CoveredCalls.{Sale, Sales}
  alias Autolaunch.Points.CoveredCall
  alias RegentChain.Event

  @covered "autolaunch.first_covered_call"
  @seller "0x" <> String.duplicate("a", 40)
  @buyer "0x" <> String.duplicate("b", 40)
  @stranger "0x" <> String.duplicate("d", 40)
  @deployed 100
  @head 120
  @fill_transaction "0x" <> String.duplicate("1a", 32)
  @sale_transaction "0x" <> String.duplicate("2b", 32)
  @filled "Filled(uint256,address,uint256,uint256,uint256)"
  @sold "SoldToBid(uint256,uint256,address,uint256,uint256,uint256)"

  defmodule Chain do
    @moduledoc false

    # Contract reads go to the market's double; the rest is this chain.
    def post(url, options) do
      %{method: method, params: params} = options[:json]
      state = Application.fetch_env!(:autolaunch, :points_covered_call_chain)
      send(state.test, {:rpc, method, params})

      if method == "eth_call",
        do: Autolaunch.CoveredCallsChain.post(url, options),
        else: {:ok, %{status: 200, body: %{"result" => answer(method, params, state)}}}
    end

    defp answer("eth_chainId", _params, _state), do: "0x2105"

    defp answer("eth_getBlockByNumber", ["latest", _full?], state),
      do: block(state, state.head)

    defp answer("eth_getBlockByNumber", ["0x" <> number, _full?], state),
      do: block(state, String.to_integer(number, 16))

    defp answer("eth_getCode", [_contract, "0x" <> number], state),
      do: if(String.to_integer(number, 16) >= state.deployed, do: "0x6080", else: "0x")

    defp answer("eth_getLogs", [filter], state) do
      %{address: address, fromBlock: from, toBlock: to, topics: [events]} = filter

      Enum.filter(state.logs, fn log ->
        log["address"] == address and hd(log["topics"]) in events and
          quantity(from) <= quantity(log["blockNumber"]) and
          quantity(log["blockNumber"]) <= quantity(to)
      end)
    end

    def block(state, number),
      do: %{
        "number" => "0x" <> Integer.to_string(number, 16),
        "hash" => hash(state, number),
        "timestamp" => "0x" <> Integer.to_string(state.time + number, 16)
      }

    def hash(state, number),
      do:
        Map.get_lazy(state.hashes, number, fn ->
          "0x" <> String.pad_leading(Integer.to_string(number, 16), 64, "0")
        end)

    defp quantity("0x" <> hex), do: String.to_integer(hex, 16)
  end

  setup do
    starts_at = open([@covered])

    # Listing 1 is the seller's; bid 1 is the buyer's.
    CoveredCallsChain.install(%{
      listings: [CoveredCallsChain.listing(%{seller: @seller})],
      bids: [CoveredCallsChain.bid(%{bidder: @buyer})]
    })

    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Chain)
    on_exit(fn -> Application.delete_env(:autolaunch, :points_covered_call_chain) end)

    accounts =
      for {name, wallet} <- [seller: @seller, buyer: @buyer], into: %{} do
        account =
          Accounts.register_verified!("did:privy:points-#{name}", wallet, [wallet],
            actor: %System{}
          )

        # The wallet was the account's since before earning opened.
        held_since(account, wallet, DateTime.add(starts_at, -86_400))
        {name, account}
      end

    %{seller: accounts.seller, buyer: accounts.buyer}
  end

  test "a sale earns its seller and its buyer First Autolaunch covered call, each once, however many follow",
       %{seller: seller, buyer: buyer} do
    chain([
      filled(1, @fill_transaction, 1, @buyer),
      sold(2, @sale_transaction, 1, 2, @seller)
    ])

    assert {:snooze, 300} = pass()
    assert [fill, sale] = sales()

    assert %{event: :filled, listing_id: 1, bid_id: nil, seller: @seller, buyer: @buyer} = fill
    assert %{event: :sold_to_bid, listing_id: 2, bid_id: 1, seller: @seller, buyer: @buyer} = sale
    assert fill.contract == CoveredCallsChain.contract()
    assert fill.stock == CoveredCallsChain.stock()

    assert {fill.chain_id, fill.block_number, fill.transaction_hash} ==
             {8453, @head, @fill_transaction}

    assert Decimal.equal?(fill.amount, 2 * CoveredCallsChain.unit())
    assert Decimal.equal?(fill.premium, 6_000_000)
    assert Decimal.equal?(fill.fee, 60_000)

    # Each sale is offered once for each side.
    assert length(all_enqueued(queue: :points)) == 4
    drain()

    assert Enum.sort(Enum.map(events(@covered), &{&1.account_id, &1.source_kind})) ==
             Enum.sort([{seller.id, "covered_call_seller"}, {buyer.id, "covered_call_buyer"}])

    assert [{_, 25}, {_, 25}] = earned(@covered)
    assert rejections(fill.id) ++ rejections(sale.id) == []
  end

  test "an account on both sides of a sale earns it once", %{seller: seller} do
    CoveredCallsChain.put(%{bids: [CoveredCallsChain.bid(%{bidder: @seller})]})
    chain([sold(1, @sale_transaction, 1, 2, @seller)])

    assert {:snooze, 300} = pass()
    assert [%{id: id, seller: @seller, buyer: @seller}] = sales()
    drain()

    seller_id = seller.id
    assert [%{account_id: ^seller_id}] = events(@covered)
    assert earned(@covered) == [{id, 25}]
    assert rejections(id) == []
  end

  test "reading a sale again keeps it as first saved and offers nothing" do
    chain([filled(1, @fill_transaction, 1, @buyer)])
    assert {:snooze, 300} = pass()
    assert [saved] = sales()
    queued = all_enqueued(queue: :points)

    # The head moves on, and the next pass reads the sale's block again.
    put(head: 130)
    assert {:snooze, 300} = pass()
    assert sales() == [saved]
    assert all_enqueued(queue: :points) == queued
    assert %{next_block: 131, rescan_from: nil} = cursor()

    drain()
    assert [{_, 25}, {_, 25}] = earned(@covered)
  end

  test "a sale with a side no account holds is saved and earns only the linked side",
       %{seller: seller} do
    chain([filled(1, @fill_transaction, 1, @stranger)])

    assert {:snooze, 300} = pass()
    assert [%{id: id, buyer: @stranger}] = sales()
    drain()

    seller_id = seller.id
    assert [%{account_id: ^seller_id, source_kind: "covered_call_seller"}] = events(@covered)
    assert rejections(id) == [{@covered, "buyer_wallet_not_linked"}]
  end

  test "while earning is closed, the reader still saves a sale and Points gets nothing" do
    close()
    chain([filled(1, @fill_transaction, 1, @buyer)])

    assert {:snooze, 300} = pass()
    assert [_sale] = sales()
    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
  end

  test "with covered calls off or their contracts not described, the reader reads nothing" do
    chain([filled(1, @fill_transaction, 1, @buyer)])

    Application.put_env(:autolaunch, :covered_calls, :off)
    assert Sales.jobs() == []
    assert {:cancel, :covered_calls_off} = pass()

    Application.put_env(:autolaunch, :covered_calls, :on)
    Application.delete_env(:autolaunch, :autolaunch_base_covered_calls_deployment)
    assert Sales.jobs() == []
    assert {:cancel, :covered_calls_deployment_missing} = pass()

    refute_received {:rpc, _method, _params}
    assert sales() == []
    assert all_enqueued(queue: :points) == []
  end

  test "a sale the chain took back stops the reader until an operator clears it, and saved again it earns nothing more" do
    chain([filled(1, @fill_transaction, 1, @buyer)])
    assert {:snooze, 300} = pass()
    assert [saved] = sales()
    drain()

    # Block 120 is replaced, and the sale lands in block 125 instead.
    put(
      head: 130,
      hashes: %{@head => "0x" <> String.duplicate("3d", 32)},
      logs: [filled(1, @fill_transaction, 1, @buyer, block: 125)]
    )

    {result, log} = with_log(&pass/0)
    assert {:snooze, 300} = result
    assert log =~ "stopped at block 120"
    assert %{rescan_from: 120, next_block: 121} = cursor()
    assert sales() == [saved]

    # Stopped, the reader asks the chain nothing.
    flush_requests()
    assert {{:snooze, 300}, _log} = with_log(&pass/0)
    refute_received {:rpc, _method, _params}

    # The operator takes the sale out of the record and clears the stop; the
    # reader reads again from block 120.
    Repo.delete_all(from s in Sale, where: s.id == ^saved.id)

    assert capture_io(fn -> Release.clear_covered_call_sales_stop!(contract()) end) =~
             "will be read again from block 120"

    assert %{rescan_from: nil, next_block: 120, observed_at: nil} = cursor()

    assert capture_io(fn -> Release.clear_covered_call_sales_stop!(contract()) end) =~
             "is not stopped; nothing changed"

    assert {:snooze, 300} = pass()
    assert [%{block_number: 125} = moved] = sales()
    assert moved.id != saved.id
    drain()

    # Both sides had earned it already.
    assert length(events(@covered)) == 2
    assert [{_, 25}, {_, 25}] = earned(@covered)
  end

  test "a sale read again that differs from the saved one stops the reader at its block" do
    chain([filled(1, @fill_transaction, 1, @buyer)])
    assert {:snooze, 300} = pass()
    assert [saved] = sales()

    put(head: 130, logs: [filled(1, @fill_transaction, 1, @buyer, amount: 3)])
    assert {{:snooze, 300}, log} = with_log(&pass/0)
    assert log =~ "stopped at block 120"
    assert %{rescan_from: 120, next_block: 121} = cursor()
    assert sales() == [saved]
  end

  test "a pass whose cursor moved under it saves nothing and reads again at once" do
    chain([filled(1, @fill_transaction, 1, @buyer)])
    assert {:snooze, 300} = pass()

    # The next pass stops at its contract read while another moves the cursor on.
    put(head: 130, logs: [filled(2, @sale_transaction, 1, @buyer, block: 125)])

    CoveredCallsChain.put(%{
      listings: [CoveredCallsChain.listing(%{seller: @seller})],
      hold: self()
    })

    running = Task.async(&pass/0)
    assert_receive {:held, reader}, 5_000

    Autolaunch.CoveredCalls.advance_covered_call_cursor!(
      cursor(),
      %{
        from: 121,
        next_block: 131,
        head_block: 130,
        head_block_hash: Chain.hash(%{hashes: %{}}, 130),
        observed_at: DateTime.utc_now()
      },
      actor: %System{}
    )

    send(reader, :go)
    assert {:snooze, 1} = Task.await(running)
    assert [%{block_number: @head}] = sales()
    assert %{next_block: 131, rescan_from: nil} = cursor()
  end

  test "the first pass opens at the contract's deployment block, and each pass reads at most ten thousand blocks" do
    chain([filled(1, @fill_transaction, 1, @buyer, block: 20_000)])
    put(head: 25_000, deployed: 5_000)

    assert {:snooze, 1} = pass()
    assert %{next_block: 14_700} = cursor()
    assert sales() == []
    assert {:snooze, 1} = pass()
    assert [%{block_number: 20_000}] = sales()
    assert {:snooze, 300} = pass()
    assert %{next_block: 25_001, head_block: 25_000} = cursor()

    # Each search reads again the last 300 blocks the one before it read.
    assert log_ranges() == [{4_700, 14_699}, {14_400, 24_399}, {24_100, 25_000}]
  end

  test "the site's covered-call check answers the same each time it is asked",
       %{seller: seller, buyer: buyer} do
    chain([
      filled(1, @fill_transaction, 1, @stranger),
      sold(2, @sale_transaction, 1, 2, @stranger)
    ])

    assert {:snooze, 300} = pass()
    assert [fill, sale] = sales()
    missing = Ash.UUID.generate()

    for id <- [fill.id, sale.id, missing],
        side <- ["covered_call_seller", "covered_call_buyer"],
        do: assert(verify(side, id) == verify(side, id))

    seller_id = seller.id
    buyer_id = buyer.id
    fill_id = fill.id
    sale_id = sale.id

    assert {:ok, %{account_id: ^seller_id, source_event_key: ^fill_id}} =
             verify("covered_call_seller", fill.id)

    assert {:error, :buyer_wallet_not_linked} = verify("covered_call_buyer", fill.id)
    assert {:error, :seller_wallet_not_linked} = verify("covered_call_seller", sale.id)

    assert {:ok, %{account_id: ^buyer_id, source_event_key: ^sale_id}} =
             verify("covered_call_buyer", sale.id)

    assert {:error, :covered_call_not_found} = verify("covered_call_buyer", missing)
  end

  # One pass of the market's reader, as its job runs it.
  defp pass, do: perform_job(Sales, %{contract: contract()})

  defp contract, do: CoveredCallsChain.contract()

  # A saved sale has no read but the site's own check, so the test reads the rows back.
  defp sales, do: Repo.all(from s in Sale, order_by: [s.block_number, s.log_index])

  defp cursor,
    do: Autolaunch.CoveredCalls.covered_call_cursor!(8453, contract(), actor: %System{})

  defp verify(side, id),
    do: CoveredCall.verify(%{"source_kind" => side, "source_event_key" => id})

  defp flush_requests do
    receive do
      {:rpc, _method, _params} -> flush_requests()
    after
      0 -> :ok
    end
  end

  # Every log search the chain answered, as its block range.
  defp log_ranges(ranges \\ []) do
    receive do
      {:rpc, "eth_getLogs", [%{fromBlock: from, toBlock: to}]} ->
        log_ranges([{quantity(from), quantity(to)} | ranges])

      {:rpc, _method, _params} ->
        log_ranges(ranges)
    after
      0 -> Enum.reverse(ranges)
    end
  end

  # The chain the reader reads: the contract deployed at block 100, the head at
  # block 120, a minute ago, and the contract's `logs`.
  defp chain(logs) do
    Application.put_env(:autolaunch, :points_covered_call_chain, %{
      test: self(),
      head: @head,
      deployed: @deployed,
      time: DateTime.to_unix(DateTime.utc_now()) - 60 - @head,
      hashes: %{},
      logs: logs
    })
  end

  defp put(changes) do
    state = Application.fetch_env!(:autolaunch, :points_covered_call_chain)

    Application.put_env(
      :autolaunch,
      :points_covered_call_chain,
      Map.merge(state, Map.new(changes))
    )
  end

  # `buyer` buying two tokens' calls from `listing` for six USDC, one percent of it the fee.
  defp filled(index, transaction, listing, buyer, opts \\ []) do
    log(index, transaction, @filled, [listing, buyer], opts)
  end

  # `seller` selling two tokens' calls into `bid`, which opened `listing`.
  defp sold(index, transaction, bid, listing, seller, opts \\ []) do
    log(index, transaction, @sold, [bid, listing, seller], opts)
  end

  defp log(index, transaction, event, indexed, opts) do
    block = Keyword.get(opts, :block, @head)
    amount = Keyword.get(opts, :amount, 2) * CoveredCallsChain.unit()

    %{
      "removed" => false,
      "address" => contract(),
      "blockNumber" => "0x" <> Integer.to_string(block, 16),
      "blockHash" => Chain.hash(%{hashes: %{}}, block),
      "logIndex" => "0x" <> Integer.to_string(index, 16),
      "transactionHash" => transaction,
      "topics" => [Event.topic0(event) | Enum.map(indexed, &topic/1)],
      "data" => "0x" <> Enum.map_join([amount, 6_000_000, 60_000], &BaseRpcStub.hex_word/1)
    }
  end

  defp topic("0x" <> _address = address), do: BaseRpcStub.address_topic(address)
  defp topic(id), do: "0x" <> BaseRpcStub.hex_word(id)

  defp quantity("0x" <> hex), do: String.to_integer(hex, 16)
end
