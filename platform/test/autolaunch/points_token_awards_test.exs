defmodule Autolaunch.PointsTokenAwardsTest do
  # A trade or a stake the token's reader (Autolaunch.TokenTrades) saves offers Regent
  # Points its award in the same transaction, and the site's own checks
  # (Autolaunch.Points.Trade and .Stake) answer from the saved rows. The reader reads a
  # scripted Base chain: a graduated Revstake launch whose pool's swaps and splitter's
  # stakes are all in the head block, each swap sent by the wallet the chain double
  # names for its transaction.
  use Autolaunch.DataCase, async: false
  use Oban.Testing, repo: Autolaunch.Repo
  import Autolaunch.PointsTesting
  import ExUnit.CaptureLog

  alias Autolaunch.{Accounts, BaseRpcStub, Lab, LabAbi, TestSupport, TokenTrades}
  alias Autolaunch.Actors.System
  alias Autolaunch.Points.{Stake, Trade}

  @traded "autolaunch.token_traded"
  @staked "autolaunch.token_staked"
  @wallet "0x" <> String.duplicate("c", 40)
  @stranger "0x" <> String.duplicate("d", 40)
  @router "0x" <> String.duplicate("e", 40)
  @subject "0x5100000000000000000000000000000000000051"
  @splitter "0x5400000000000000000000000000000000000054"
  @pool_id "0x" <> String.pad_leading("abc", 64, "0")
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
  @head 120
  @first_transaction "0x" <> String.duplicate("1a", 32)
  @second_transaction "0x" <> String.duplicate("2b", 32)
  @third_transaction "0x" <> String.duplicate("3c", 32)

  defmodule Chain do
    @moduledoc false
    alias Autolaunch.BaseRpcStub

    # Each request is told to the test as `{:rpc, method, params}`.
    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      state = Application.fetch_env!(:autolaunch, :points_token_chain)
      send(state.test, {:rpc, method, params})

      case answer(method, params, state) do
        :refused ->
          {:ok, %{status: 200, body: %{"error" => %{"code" => -32_005, "message" => "refused"}}}}

        result ->
          {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", _params, _state), do: "0x2105"

    defp answer("eth_getBlockByNumber", ["latest", _full?], state),
      do: block(state, state.head)

    defp answer("eth_getBlockByNumber", ["0x" <> number, _full?], state),
      do: block(state, String.to_integer(number, 16))

    # The strategy's record of a migrated launch: migrated at block 100, its
    # subject token, splitter and pool.
    defp answer("eth_call", [_call, _block], _state) do
      words =
        [2, 0, 0, 0, 100, 0, 0, 0, 0, 1, 0x51 * Integer.pow(2, 152) + 0x51, 0x52, 0x53] ++
          [0x54 * Integer.pow(2, 152) + 0x54, 0x55, 0xABC, 1]

      "0x" <> Enum.map_join(words, &BaseRpcStub.hex_word/1)
    end

    # A contract `widest` names is refused any read of more blocks than it gives.
    defp answer("eth_getLogs", [filter], state) do
      %{address: address, fromBlock: from, toBlock: to, topics: [events | _]} = filter
      widest = state.widest[String.downcase(address)]

      if widest && quantity(to) - quantity(from) + 1 > widest do
        :refused
      else
        Enum.filter(state.logs, fn log ->
          String.downcase(log["address"]) == String.downcase(address) and
            hd(log["topics"]) in List.wrap(events) and
            quantity(from) <= quantity(log["blockNumber"]) and
            quantity(log["blockNumber"]) <= quantity(to)
        end)
      end
    end

    # A sender is a wallet, or the node refusing (`:refused`), never answering
    # (`:silent`) or not knowing the transaction (none); with `:raise` or
    # `:crash` the request itself fails.
    defp answer("eth_getTransactionByHash", [hash], state) do
      case state.senders[hash] do
        :refused -> :refused
        :silent -> Process.sleep(:infinity)
        :raise -> raise "the client failed"
        :crash -> exit(:crashed)
        from when is_binary(from) -> %{"hash" => hash, "from" => from}
        nil -> nil
      end
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
    starts_at = open([@traded, @staked])

    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Chain)

    on_exit(fn ->
      Application.delete_env(:autolaunch, :points_token_chain)

      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)

    account =
      Accounts.register_verified!("did:privy:points-tokens", @wallet, [@wallet], actor: %System{})

    # The wallet was the account's since before earning opened.
    held_since(account, @wallet, DateTime.add(starts_at, -86_400))

    auction =
      TestSupport.project_auction(chain_id: 8453, state: :graduated, token_address: @subject)

    token =
      TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    %{account: account, auction: auction, token: token}
  end

  test "a trade from a linked wallet earns the day's trade award once, a second that day counting at nothing",
       %{account: account, token: token} do
    # The node may name a sender in mixed case; the trade saves it in lowercase.
    chain(
      [swap(1, @first_transaction), swap(2, @second_transaction)],
      %{@first_transaction => @wallet, @second_transaction => "0x" <> String.duplicate("C", 40)}
    )

    assert {:snooze, 300} = pass(token)
    assert [%{trader: @wallet}, %{trader: @wallet}] = trades = trades(token)
    drain()

    # Whichever of the two Points checks first earns the day's award.
    earned = Map.new(earned(@traded))
    assert Enum.sort(Map.keys(earned)) == Enum.sort(Enum.map(trades, &Trade.key/1))
    assert Enum.sort(Map.values(earned)) == [0, 10]

    account_id = account.id
    assert [%{account_id: ^account_id}, %{account_id: ^account_id}] = events(@traded)
  end

  test "reading the same block again keeps each trade and its trader and offers nothing",
       %{token: token} do
    chain([swap(1, @first_transaction)], %{@first_transaction => @wallet})
    assert {:snooze, 300} = pass(token)
    assert [%{trader: @wallet} = saved] = trades(token)
    queued = all_enqueued(queue: :points)
    assert length(queued) == 1

    # The head has not moved, so the next pass reads its block again. Even a node
    # naming another sender for the transaction never changes the saved trader.
    put(senders: %{@first_transaction => @stranger})
    assert {:snooze, 300} = pass(token)
    assert trades(token) == [saved]
    assert all_enqueued(queue: :points) == queued

    drain()
    assert [{key, 10}] = earned(@traded)
    assert key == Trade.key(saved)
  end

  test "a rebuild after the chain changed saves each trade again, and Points records it once",
       %{token: token} do
    chain([swap(1, @first_transaction)], %{@first_transaction => @wallet})
    assert {:snooze, 300} = pass(token)
    assert [saved] = trades(token)
    drain()
    {:ok, facts} = Trade.verify(%{"source_event_key" => Trade.key(saved)})

    # The head block is replaced, with the same swap in it: the reader drops the
    # token's trades and reads them again from the launch's migration.
    reorged = "0x" <> String.duplicate("3d", 32)
    put(hashes: %{@head => reorged}, logs: [swap(1, @first_transaction, block_hash: reorged)])
    assert {:snooze, 1} = pass(token)
    assert trades(token) == []
    assert {:snooze, 300} = pass(token)
    assert [%{trader: @wallet, block_hash: ^reorged} = rebuilt] = trades(token)
    assert rebuilt.id != saved.id

    # Saved again, the trade is offered again under the same key, which Points
    # already holds with the same facts.
    assert [_offered] = all_enqueued(queue: :points)
    assert Trade.verify(%{"source_event_key" => Trade.key(rebuilt)}) == {:ok, facts}
    drain()
    assert [%{source_event_key: key}] = events(@traded)
    assert [{^key, 10}] = earned(@traded)
  end

  test "a trade from a wallet no account holds is saved and earns nothing", %{token: token} do
    chain([swap(1, @first_transaction)], %{@first_transaction => @stranger})

    assert {:snooze, 300} = pass(token)
    assert [%{trader: @stranger} = trade] = trades(token)
    drain()

    assert events(@traded) == []
    assert rejections(Trade.key(trade)) == [{@traded, "trader_wallet_not_linked"}]
  end

  test "while earning is closed, the reader still saves a trade with its trader and Points gets nothing",
       %{token: token} do
    close()
    chain([swap(1, @first_transaction)], %{@first_transaction => @wallet})

    assert {:snooze, 300} = pass(token)
    assert [%{trader: @wallet}] = trades(token)
    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
    assert RegentPoints.read_rejections!(actor: RegentPoints.Store.system()) == []
  end

  test "a pass asks the node only about transactions with a trade not saved yet",
       %{token: token} do
    chain([swap(1, @first_transaction)], %{@first_transaction => @wallet})
    assert {:snooze, 300} = pass(token)
    assert [%{trader: @wallet} = saved] = trades(token)
    assert lookups() == [@first_transaction]
    assert [_offered] = all_enqueued(queue: :points)

    # Caught up, the next pass reads the head block again and asks about nothing.
    assert {:snooze, 300} = pass(token)
    assert lookups() == []

    # A new swap read beside the saved one is the only transaction asked about, and
    # the saved trade keeps its trader whatever the node would now say.
    put(
      logs: [swap(1, @first_transaction), swap(2, @second_transaction)],
      senders: %{@first_transaction => @stranger, @second_transaction => @wallet}
    )

    assert {:snooze, 300} = pass(token)
    assert lookups() == [@second_transaction]
    assert [^saved, %{trader: @wallet} = added] = trades(token)
    assert [_first, _second] = all_enqueued(queue: :points)

    drain()
    keys = Enum.map(events(@traded), & &1.source_event_key)
    assert Enum.sort(keys) == Enum.sort([Trade.key(saved), Trade.key(added)])
  end

  test "a trader lookup the node refuses, does not know or never answers in a one-block pass leaves it quietly to be read again, with nothing saved",
       %{token: token} do
    read_to_head(token)

    for sender <- [:refused, nil, :silent] do
      chain([swap(1, @first_transaction)], %{@first_transaction => sender})

      {{micros, result}, log} = with_log(fn -> :timer.tc(fn -> pass(token) end) end)

      assert result == {:snooze, 60}
      assert warnings(log) == 1
      assert log =~ "transactions_unavailable"
      # One lookup's round is given three seconds.
      assert micros < 10_000_000
      assert trades(token) == []
      assert %{trades_next_block: @head} = Ash.reload!(token, authorize?: false)
    end

    assert all_enqueued(queue: :points) == []
  end

  test "a trader lookup that crashes ends the pass as the quiet wait, never a job error",
       %{token: token} do
    read_to_head(token)

    for sender <- [:raise, :crash] do
      chain([swap(1, @first_transaction)], %{@first_transaction => sender})

      {result, _log} = with_log(fn -> pass(token) end)

      assert result == {:snooze, 60}
      assert trades(token) == []
      assert %{trades_next_block: @head} = Ash.reload!(token, authorize?: false)
    end
  end

  test "a range with more new transactions than one ask takes is read in narrowed passes, every trade saved with its trader",
       %{token: token} do
    # As after a rebuild: nothing saved, and five swaps in each of blocks 101 to
    # 120, each its own transaction, a hundred transactions to ask about.
    swaps =
      for block <- 101..120, index <- 1..5 do
        swap(index, transaction(block * 10 + index), block: block)
      end

    chain(swaps, Map.new(swaps, &{&1["transactionHash"], @wallet}))

    # 100 to 120 holds 100, 100 to 110 holds 50: the first pass asks about the 25
    # in 100 to 105. The second asks about the 40 in 106 to 113, the third the rest.
    assert {:snooze, 1} = pass(token)
    assert %{trades_next_block: 106} = Ash.reload!(token, authorize?: false)
    assert length(lookups()) == 25

    assert {:snooze, 1} = pass(token)
    assert %{trades_next_block: 114} = Ash.reload!(token, authorize?: false)
    assert length(lookups()) == 40

    assert {:snooze, 300} = pass(token)
    assert length(lookups()) == 35

    saved = trades(token)
    assert length(saved) == 100
    assert Enum.all?(saved, &(&1.trader == @wallet))
  end

  test "lookups that fail for a wide range read its first half instead, and the cursor moves only that far",
       %{token: token} do
    # The node does not know the transaction in block 120 yet.
    chain(
      [swap(1, @first_transaction, block: 104), swap(2, @second_transaction)],
      %{@first_transaction => @wallet}
    )

    assert {:snooze, 1} = pass(token)
    assert @second_transaction in lookups()
    assert %{trades_next_block: 111} = Ash.reload!(token, authorize?: false)
    assert [%{block_number: 104, trader: @wallet}] = trades(token)
    assert [_offered] = all_enqueued(queue: :points)
  end

  test "one block holding more new transactions than one ask takes is asked about whole and saved",
       %{token: token} do
    # 45 swaps in block 100, where the launch migrated and the first pass begins.
    swaps = for index <- 1..45, do: swap(index, transaction(index), block: 100)
    chain(swaps, Map.new(swaps, &{&1["transactionHash"], @wallet}))

    assert {:snooze, 1} = pass(token)
    assert length(lookups()) == 45
    assert %{trades_next_block: 101} = Ash.reload!(token, authorize?: false)
    saved = trades(token)
    assert length(saved) == 45
    assert Enum.all?(saved, &(&1.trader == @wallet))
  end

  test "the site's check answers the same each time it is asked",
       %{account: account, auction: auction, token: token} do
    chain([swap(1, @first_transaction)], %{@first_transaction => @wallet})
    assert {:snooze, 300} = pass(token)
    assert [trade] = trades(token)

    # A trade saved before the site recorded traders has none.
    untraced =
      Ash.create!(
        Autolaunch.TokenTrade,
        %{
          token_id: token.id,
          transaction_hash: @second_transaction,
          block_hash: Chain.hash(%{hashes: %{}}, 110),
          block_number: 110,
          log_index: 4,
          occurred_at: trade.occurred_at,
          side: :buy,
          currency_amount: Decimal.new(1),
          currency_symbol: "REGENT",
          token_amount: Decimal.new(2)
        },
        action: :record,
        actor: %System{}
      )

    missing = %{token_id: token.id, transaction_hash: @second_transaction, log_index: 9}

    for record <- [trade, untraced, missing],
        do: assert(verify(record) == verify(record))

    account_id = account.id
    key = Trade.key(trade)
    assert {:ok, %{account_id: ^account_id, source_event_key: ^key}} = verify(trade)
    assert {:error, :trader_unknown} = verify(untraced)
    assert {:error, :trade_not_found} = verify(missing)

    # A token whose launch an operator hid earns nothing for its trades.
    Autolaunch.hide_auction!(auction, actor: %System{})
    assert {:error, :trade_not_listed} = verify(trade)
  end

  test "a stake from a linked wallet earns Autolaunch token staked once, though the wallet stakes again",
       %{account: account, token: token} do
    chain([
      stake_log(1, @first_transaction, @wallet),
      stake_log(2, @second_transaction, @wallet),
      # Unstaking is not read.
      stake_log(3, @second_transaction, @wallet, event: "Unstaked(address,uint256)")
    ])

    assert {:snooze, 300} = pass(token)
    assert [%{staker: @wallet} = first, %{staker: @wallet} = second] = stakes(token)
    assert first.splitter == @splitter
    assert first.chain_id == 8453
    assert Decimal.equal?(first.amount, Decimal.new(5 * Integer.pow(10, 18)))
    drain()

    # Both are recorded for the account; whichever Points checks first earns it,
    # and the other ends capped with no entry of its own.
    assert [{key, 40}] = earned(@staked)
    [other] = [first.id, second.id] -- [key]
    assert outcomes(@staked) == Enum.sort([{key, :confirmed}, {other, :capped}])
    assert Enum.map(events(@staked), & &1.account_id) == [account.id, account.id]
  end

  test "reading a stake again, or rebuilding after the chain changed, keeps it as first saved and offers nothing",
       %{token: token} do
    chain([stake_log(1, @first_transaction, @wallet)])
    assert {:snooze, 300} = pass(token)
    assert [saved] = stakes(token)
    drain()
    assert [{_key, 40}] = earned(@staked)

    # The head has not moved, so the next pass reads the stake again.
    assert {:snooze, 300} = pass(token)
    assert stakes(token) == [saved]
    assert all_enqueued(queue: :points) == []

    # The head block is replaced, with the same stake in it: the reader rebuilds
    # the token's trades, and the stake keeps the block it was first saved in.
    reorged = "0x" <> String.duplicate("3d", 32)

    put(
      hashes: %{@head => reorged},
      logs: [stake_log(1, @first_transaction, @wallet, block_hash: reorged)]
    )

    assert {:snooze, 1} = pass(token)
    assert {:snooze, 300} = pass(token)
    assert stakes(token) == [saved]
    assert all_enqueued(queue: :points) == []
    assert [{_key, 40}] = earned(@staked)
  end

  test "a stake from a wallet no account holds is saved and earns nothing", %{token: token} do
    chain([stake_log(1, @first_transaction, @stranger)])

    assert {:snooze, 300} = pass(token)
    assert [%{id: id, staker: @stranger}] = stakes(token)
    drain()

    assert events(@staked) == []
    assert rejections(id) == [{@staked, "staker_wallet_not_linked"}]
  end

  test "while earning is closed, the reader still saves a stake and Points gets nothing",
       %{token: token} do
    close()
    chain([stake_log(1, @first_transaction, @wallet)])

    assert {:snooze, 300} = pass(token)
    assert [%{staker: @wallet}] = stakes(token)
    assert all_enqueued(queue: :points) == []
    drain()
    assert events() == []
  end

  test "a splitter read the node refuses as too wide narrows the pass, and every trade and stake is still saved",
       %{token: token} do
    chain(
      [
        swap(1, @first_transaction, block: 104),
        stake_log(2, @second_transaction, @wallet, block: 104),
        stake_log(1, @third_transaction, @wallet)
      ],
      %{@first_transaction => @wallet}
    )

    put(widest: %{@splitter => 10})

    # The launch migrated at block 100: the splitter refuses its 21 blocks to the
    # head, then 11, and the pass saves blocks 100 to 105.
    assert {:snooze, 1} = pass(token)
    assert %{trades_next_block: 106} = Ash.reload!(token, authorize?: false)
    assert [%{block_number: 104, trader: @wallet}] = trades(token)
    assert [%{block_number: 104}] = stakes(token)

    assert {:snooze, 1} = pass(token)
    assert {:snooze, 300} = pass(token)
    assert [%{block_number: 104}, %{block_number: @head}] = stakes(token)
  end

  test "a stake log from another block than the one read under its number leaves the pass quietly to be read again",
       %{token: token} do
    moved = "0x" <> String.duplicate("4e", 32)

    chain(
      [
        swap(1, @first_transaction),
        stake_log(2, @second_transaction, @wallet, block_hash: moved)
      ],
      %{@first_transaction => @wallet}
    )

    {result, log} = with_log(fn -> pass(token) end)

    assert result == {:snooze, 60}
    assert warnings(log) == 1
    assert log =~ "head_moved"
    assert trades(token) == []
    assert stakes(token) == []
    assert %{trades_next_block: nil} = Ash.reload!(token, authorize?: false)
  end

  test "a Staked log of nothing is skipped and the pass goes on", %{token: token} do
    chain([
      stake_log(1, @first_transaction, @wallet, amount: 0),
      stake_log(2, @second_transaction, @wallet)
    ])

    assert {:snooze, 300} = pass(token)
    assert [%{log_index: 2} = saved] = stakes(token)

    # A stake of nothing is not one the site saves.
    zero =
      saved
      |> Map.take([:token_id, :chain_id, :splitter, :staker, :block_number, :block_hash])
      |> Map.merge(%{
        transaction_hash: @first_transaction,
        log_index: 1,
        occurred_at: saved.occurred_at,
        amount: Decimal.new(0)
      })

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(Autolaunch.TokenStake, zero, action: :record, actor: %System{})
  end

  test "the site's stake check answers the same each time it is asked",
       %{account: account, auction: auction, token: token} do
    chain([
      stake_log(1, @first_transaction, @wallet),
      stake_log(2, @second_transaction, @stranger)
    ])

    assert {:snooze, 300} = pass(token)
    assert [stake, stranger] = stakes(token)
    missing = Ash.UUID.generate()

    for id <- [stake.id, stranger.id, missing],
        do: assert(Stake.verify(key(id)) == Stake.verify(key(id)))

    account_id = account.id
    id = stake.id
    assert {:ok, %{account_id: ^account_id, source_event_key: ^id}} = Stake.verify(key(id))
    assert {:error, :staker_wallet_not_linked} = Stake.verify(key(stranger.id))
    assert {:error, :stake_not_found} = Stake.verify(key(missing))

    # A token whose launch an operator hid earns nothing for its stakes.
    Autolaunch.hide_auction!(auction, actor: %System{})
    assert {:error, :stake_not_listed} = Stake.verify(key(id))
  end

  # One pass of the token's reader, as its job runs it.
  defp pass(token), do: perform_job(TokenTrades, %{token_id: token.id})

  defp trades(token), do: Autolaunch.token_trades!(token.id, actor: nil)

  # A saved stake has no read but the site's own check, so the test reads the
  # token's rows back.
  defp stakes(token) do
    Repo.all(
      from s in Autolaunch.TokenStake,
        where: s.token_id == ^token.id,
        order_by: [s.block_number, s.log_index]
    )
  end

  defp verify(trade), do: Trade.verify(%{"source_event_key" => Trade.key(trade)})

  defp key(id), do: %{"source_event_key" => id}

  # The chain the reader reads: the head at block 120, a minute ago, and the pool's
  # and splitter's `logs`, each swap sent by the wallet `senders` names for its
  # transaction. Every request it answers is told to this test.
  defp chain(logs, senders \\ %{}) do
    Application.put_env(:autolaunch, :points_token_chain, %{
      head: @head,
      time: DateTime.to_unix(DateTime.utc_now()) - 60 - @head,
      hashes: %{},
      logs: logs,
      senders: senders,
      widest: %{},
      test: self()
    })
  end

  defp put(changes) do
    state = Application.fetch_env!(:autolaunch, :points_token_chain)
    Application.put_env(:autolaunch, :points_token_chain, Map.merge(state, Map.new(changes)))
  end

  # The transactions the reader asked the node about since this was last asked.
  defp lookups do
    receive do
      {:rpc, "eth_getTransactionByHash", [hash]} -> [hash | lookups()]
    after
      0 -> []
    end
  end

  defp warnings(log), do: length(Regex.scan(~r/\[warning\]/, log))

  defp transaction(number), do: "0x" <> Base.encode16(<<number::256>>, case: :lower)

  # The token read up to the block before the head, so its next pass reads the head
  # block alone.
  defp read_to_head(token) do
    Repo.update_all(from(t in Autolaunch.Token, where: t.id == ^token.id),
      set: [trades_next_block: @head, trades_last_hash: Chain.hash(%{hashes: %{}}, @head - 1)]
    )
  end

  # A swap in the head block (or `block:`), through the router: one token side
  # paid in and the other taken out.
  defp swap(index, transaction, opts \\ []) do
    block = Keyword.get(opts, :block, @head)

    %{
      "removed" => false,
      "address" => Lab.address!(Lab.current!(), :pool_manager),
      "blockNumber" => "0x" <> Integer.to_string(block, 16),
      "blockHash" => Keyword.get(opts, :block_hash, Chain.hash(%{hashes: %{}}, block)),
      "logIndex" => "0x" <> Integer.to_string(index, 16),
      "transactionHash" => transaction,
      "topics" => [LabAbi.topic(@swap), @pool_id, BaseRpcStub.address_topic(@router)],
      "data" =>
        "0x" <>
          Enum.map_join(
            [-1_000_000_000_000_000_000, 2_000_000_000_000_000_000, 0, 0, 0, 0],
            &Base.encode16(<<&1::signed-256>>, case: :lower)
          )
    }
  end

  # `wallet` staking five tokens (or `amount:`) in the launch's splitter, in the
  # head block (or `block:`), or unstaking them, with `event:`.
  defp stake_log(index, transaction, wallet, opts \\ []) do
    block = Keyword.get(opts, :block, @head)

    %{
      "removed" => false,
      "address" => @splitter,
      "blockNumber" => "0x" <> Integer.to_string(block, 16),
      "blockHash" => Keyword.get(opts, :block_hash, Chain.hash(%{hashes: %{}}, block)),
      "logIndex" => "0x" <> Integer.to_string(index, 16),
      "transactionHash" => transaction,
      "topics" => [
        LabAbi.topic(Keyword.get(opts, :event, "Staked(address,uint256)")),
        BaseRpcStub.address_topic(wallet)
      ],
      "data" => BaseRpcStub.uint(Keyword.get(opts, :amount, 5 * Integer.pow(10, 18)))
    }
  end
end
