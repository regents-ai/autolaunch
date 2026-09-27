defmodule Autolaunch.AuctionFinishTest do
  @moduledoc """
  The finisher never sends a launch a second `migrate` while the chain has not
  settled the first, whatever happens after it signs: a lost broadcast answer,
  a worker that dies mid-send, or a transaction the network holds for minutes.
  Every signed transaction is recorded before it is broadcast, and one wallet's
  recorded nonces are distinct even when two launches are finished at once.
  """

  use Autolaunch.DataCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Transaction
  alias Autolaunch.Stocks.Lab, as: StocksLab

  # Anvil's public test account 9, from the well-known "test … junk" mnemonic.
  @key "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6"
  @signer "0xa0ee7a142d267c1f36714e4a8f75612f20a79720"
  @actor %System{}

  defmodule Chain do
    @moduledoc """
    One scripted chain: a Memestake launchpad whose launches are all running
    and past their migration block, and a network that holds, mines or forgets
    the transactions broadcast to it.
    """

    use Agent

    def start_link(chain_id) do
      Agent.start_link(
        fn ->
          %{
            chain_id: chain_id,
            lifecycle: 1,
            mined: 0,
            mempool: [],
            receipts: %{},
            broadcasts: [],
            on_send: :accept
          }
        end,
        name: __MODULE__
      )
    end

    def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
    def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

    @doc "Mines every held transaction with this receipt status."
    def mine(status) do
      Agent.update(__MODULE__, fn chain ->
        receipts = Map.new(chain.mempool, &{&1, %{"status" => status}})

        %{
          chain
          | mempool: [],
            mined: chain.mined + length(chain.mempool),
            receipts: Map.merge(chain.receipts, receipts)
        }
      end)
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]

      case answer(method, params) do
        {:error, message} -> {:ok, %{status: 200, body: %{"error" => %{"message" => message}}}}
        result -> {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp answer("eth_chainId", []), do: quantity(get(:chain_id))

    defp answer("eth_getBlockByNumber", ["latest", false]),
      do: %{
        "number" => quantity(100),
        "hash" => "0x" <> String.duplicate("5a", 32),
        "baseFeePerGas" => quantity(1_000_000_000)
      }

    # `launches(uint256)`: twenty words, auction at 3, migration block at 8
    # and the lifecycle at 11.
    defp answer("eth_call", [%{data: "0x" <> _data}, _block]) do
      words =
        List.duplicate(0, 20)
        |> List.replace_at(8, 10)
        |> List.replace_at(11, get(:lifecycle))

      "0x" <> Enum.map_join(words, &word/1)
    end

    defp answer("eth_estimateGas", [_call]), do: quantity(200_000)
    defp answer("eth_maxPriorityFeePerGas", []), do: quantity(1_000_000)

    defp answer("eth_getTransactionCount", [_signer, "latest"]), do: quantity(get(:mined))

    defp answer("eth_getTransactionCount", [_signer, "pending"]),
      do: quantity(get(:mined) + length(get(:mempool)))

    defp answer("eth_getTransactionReceipt", [hash]), do: Map.get(get(:receipts), hash)

    defp answer("eth_getTransactionByHash", [hash]) do
      if hash in get(:mempool) or Map.has_key?(get(:receipts), hash),
        do: %{"hash" => hash},
        else: nil
    end

    defp answer("eth_sendRawTransaction", [raw]) do
      hash = hash(raw)
      on_send = get(:on_send)

      Agent.update(__MODULE__, fn chain ->
        held = if on_send == :refuse, do: chain.mempool, else: chain.mempool ++ [hash]
        %{chain | broadcasts: chain.broadcasts ++ [raw], mempool: Enum.uniq(held)}
      end)

      case on_send do
        :accept -> hash
        :lose_answer -> {:error, "timeout"}
        :refuse -> {:error, "refused"}
        :die -> exit(:worker_killed)
      end
    end

    def hash("0x" <> raw) do
      digest = :jose_jwa_sha3.keccak(1088, 512, Base.decode16!(raw, case: :lower), 1, 32)
      "0x" <> Base.encode16(digest, case: :lower)
    end

    defp quantity(value), do: "0x" <> Integer.to_string(value, 16)

    defp word(value),
      do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
  end

  setup do
    previous_client = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    previous_key = Application.get_env(:autolaunch, :auction_finisher_key)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, Chain)
    Application.put_env(:autolaunch, :auction_finisher_key, @key)

    on_exit(fn ->
      restore(:autolaunch_lab_http_client, previous_client)
      restore(:auction_finisher_key, previous_key)
    end)

    config = StocksLab.current!()
    start_supervised!({Chain, config.chain_id})

    %{config: config}
  end

  test "a lost broadcast answer is never followed by a second transaction", %{config: config} do
    finish = running_launch(config, 1)
    Chain.put(:on_send, :lose_answer)

    assert {:error, _reason} = finish!(finish)
    assert [recorded] = transactions()
    assert Chain.get(:broadcasts) == [recorded.raw_transaction]

    Chain.put(:on_send, :accept)
    assert {:ok, _finish} = finish!(finish)
    assert {:ok, _finish} = finish!(finish)

    assert [^recorded] = transactions()
    assert Chain.get(:broadcasts) == [recorded.raw_transaction]
  end

  test "a worker that dies right after its broadcast leaves the transaction recorded",
       %{config: config} do
    finish = running_launch(config, 1)
    Chain.put(:on_send, :die)

    assert catch_exit(finish!(finish)) == :worker_killed
    assert [recorded] = transactions()
    assert recorded.state == :signed

    Chain.put(:on_send, :accept)
    assert {:ok, _finish} = finish!(finish)
    assert Chain.get(:broadcasts) == [recorded.raw_transaction]

    Chain.mine("0x1")
    Chain.put(:lifecycle, 2)
    assert {:ok, %{state: :graduated}} = finish!(finish)
    assert [%{state: :mined, nonce: 0}] = transactions()
    assert Chain.get(:broadcasts) == [recorded.raw_transaction]
  end

  test "a transaction pending for ten minutes is waited for, never replaced",
       %{config: config} do
    finish = running_launch(config, 1)

    assert {:ok, _finish} = finish!(finish)
    assert [recorded] = transactions()
    age!(recorded, 600)

    for _run <- 1..3, do: assert({:ok, %{state: :running}} = finish!(finish))

    assert [%{state: :signed}] = transactions()
    assert Chain.get(:broadcasts) == [recorded.raw_transaction]
  end

  test "a transaction the network never saw is broadcast again exactly as signed",
       %{config: config} do
    finish = running_launch(config, 1)
    Chain.put(:on_send, :refuse)

    assert {:error, _reason} = finish!(finish)
    assert [recorded] = transactions()

    Chain.put(:on_send, :accept)
    assert {:ok, _finish} = finish!(finish)

    assert [^recorded] = transactions()
    assert Chain.get(:broadcasts) == [recorded.raw_transaction, recorded.raw_transaction]
  end

  test "a transaction whose nonce another used is dropped, and the launch is sent again",
       %{config: config} do
    finish = running_launch(config, 1)
    Chain.put(:on_send, :refuse)
    assert {:error, _reason} = finish!(finish)

    # Someone else's transaction from this wallet took nonce 0.
    Chain.put(:mined, 1)
    Chain.put(:on_send, :accept)
    assert {:ok, _finish} = finish!(finish)

    assert [%{nonce: 0, state: :dropped}, %{nonce: 1, state: :signed}] = transactions()
  end

  test "two launches finished at once from one wallet get distinct recorded nonces",
       %{config: config} do
    finishes = [running_launch(config, 1), running_launch(config, 2)]

    finishes
    |> Enum.map(&Task.async(fn -> finish!(&1) end))
    |> Enum.each(&assert({:ok, _finish} = Task.await(&1)))

    assert [first, second] = transactions()
    assert {first.nonce, second.nonce} == {0, 1}
    assert first.auction_finish_id != second.auction_finish_id
    assert first.signer == @signer and second.signer == @signer

    assert Enum.sort(Chain.get(:broadcasts)) ==
             Enum.sort([first.raw_transaction, second.raw_transaction])
  end

  # The wallet's pending count cannot tell the second launch that the first
  # holds nonce 0 when the network has not taken the first, so the recorded
  # nonces have to.
  test "a nonce recorded but not yet on the network is never reserved again",
       %{config: config} do
    Chain.put(:on_send, :refuse)
    finishes = [running_launch(config, 1), running_launch(config, 2)]

    finishes
    |> Enum.map(&Task.async(fn -> finish!(&1) end))
    |> Enum.each(&assert({:error, _reason} = Task.await(&1)))

    assert [%{nonce: 0}, %{nonce: 1}] = transactions()
  end

  defp running_launch(config, launch_id) do
    Autolaunch.record_auction_finish!(
      %{
        launchpad: :base_memestake,
        chain_id: config.chain_id,
        contract: StocksLab.address!(config, :launchpad),
        launch_id: launch_id,
        auction: "0x" <> String.pad_leading(Integer.to_string(launch_id), 40, "0"),
        migration_block: 10,
        state: :running
      },
      actor: @actor
    )
  end

  defp finish!(finish) do
    finish
    |> Ash.Changeset.for_update(:finish, %{}, actor: @actor)
    |> Ash.update()
  end

  defp transactions do
    Transaction
    |> Ash.Query.sort(nonce: :asc)
    |> Ash.read!(actor: @actor)
  end

  defp age!(transaction, seconds) do
    Repo.query!(
      "UPDATE autolaunch_app.auction_finish_transactions SET inserted_at = inserted_at - make_interval(secs => $1) WHERE id = $2",
      [seconds, Ecto.UUID.dump!(transaction.id)]
    )
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
