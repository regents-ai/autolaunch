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

  defmodule Chain do
    @moduledoc false
    alias Autolaunch.BaseRpcStub

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      state = Application.fetch_env!(:autolaunch, :points_token_chain)
      {:ok, %{status: 200, body: %{"result" => answer(method, params, state)}}}
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

    defp answer("eth_getLogs", [filter], state) do
      %{address: address, fromBlock: from, toBlock: to, topics: [events | _]} = filter

      Enum.filter(state.logs, fn log ->
        String.downcase(log["address"]) == String.downcase(address) and
          hd(log["topics"]) in List.wrap(events) and
          quantity(from) <= quantity(log["blockNumber"]) and
          quantity(log["blockNumber"]) <= quantity(to)
      end)
    end

    defp answer("eth_getTransactionByHash", [hash], state) do
      with from when is_binary(from) <- state.senders[hash],
           do: %{"hash" => hash, "from" => from}
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
    put(hashes: %{@head => reorged}, logs: [swap(1, @first_transaction, reorged)])
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

  test "a transaction the node does not name leaves the pass to be read again, with nothing saved",
       %{token: token} do
    chain([swap(1, @first_transaction)], %{})

    assert {:snooze, 60} = pass(token)
    assert trades(token) == []
    assert %{trades_next_block: nil} = Ash.reload!(token, authorize?: false)
    assert all_enqueued(queue: :points) == []
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

    # Whichever of the two Points checks first earns it; the other records nothing.
    assert [{key, 40}] = earned(@staked)
    assert key in [first.id, second.id]
    account_id = account.id
    assert [%{account_id: ^account_id}] = events(@staked)
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
      from s in Autolaunch.TokenStake, where: s.token_id == ^token.id, order_by: s.log_index
    )
  end

  defp verify(trade), do: Trade.verify(%{"source_event_key" => Trade.key(trade)})

  defp key(id), do: %{"source_event_key" => id}

  # The chain the reader reads: the head at block 120, a minute ago, and the pool's
  # and splitter's `logs`, each swap sent by the wallet `senders` names for its
  # transaction.
  defp chain(logs, senders \\ %{}) do
    Application.put_env(:autolaunch, :points_token_chain, %{
      head: @head,
      time: DateTime.to_unix(DateTime.utc_now()) - 60 - @head,
      hashes: %{},
      logs: logs,
      senders: senders
    })
  end

  defp put(changes) do
    state = Application.fetch_env!(:autolaunch, :points_token_chain)
    Application.put_env(:autolaunch, :points_token_chain, Map.merge(state, Map.new(changes)))
  end

  # A swap in the head block, through the router: one token side paid in and the
  # other taken out.
  defp swap(index, transaction, block_hash \\ Chain.hash(%{hashes: %{}}, @head)) do
    %{
      "removed" => false,
      "address" => Lab.address!(Lab.current!(), :pool_manager),
      "blockNumber" => "0x" <> Integer.to_string(@head, 16),
      "blockHash" => block_hash,
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

  # `wallet` staking five tokens in the launch's splitter, in the head block (or
  # unstaking them, with `event:`).
  defp stake_log(index, transaction, wallet, opts \\ []) do
    %{
      "removed" => false,
      "address" => @splitter,
      "blockNumber" => "0x" <> Integer.to_string(@head, 16),
      "blockHash" => Keyword.get(opts, :block_hash, Chain.hash(%{hashes: %{}}, @head)),
      "logIndex" => "0x" <> Integer.to_string(index, 16),
      "transactionHash" => transaction,
      "topics" => [
        LabAbi.topic(Keyword.get(opts, :event, "Staked(address,uint256)")),
        BaseRpcStub.address_topic(wallet)
      ],
      "data" => BaseRpcStub.uint(5 * Integer.pow(10, 18))
    }
  end
end
