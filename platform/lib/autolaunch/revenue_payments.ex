defmodule Autolaunch.RevenuePayments do
  @moduledoc """
  A bounded, browser-independent projection of the confirmed payments into
  each graduated Base Revstake launch's revenue split: every `PaymentRouted`
  its canonical payment receiver emitted, from the block the launch migrated
  in. Each pass reads one launch and at most 2,000 blocks. The cursor and rows
  commit together, and a repeated range replaces the same rows. A changed
  cursor block invalidates the launch's payment history and rebuilds it from
  the chain. Nothing pending is ever stored and nothing is ever sent.
  """
  @behaviour Autolaunch.DurableWork.Handler
  import Ecto.Query
  require Ash.Query
  require Logger
  alias Autolaunch.Actors.System
  alias Autolaunch.{Auction, Lab, LabAbi, LabRpc, Pool, Repo, RevenuePayment}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Stocks.Amounts

  @actor %System{}
  @transfer "Transfer(address,address,uint256)"
  @range 2_000
  @rows 200
  @retry_seconds 60
  @caught_up_seconds 10

  def poll(_context, 0), do: []
  def poll(_context, _capacity), do: [:next]

  def handle(_context, :next) do
    case claim(Lab.chain_id()) do
      {:ok, nil} ->
        :ok

      {:ok, auction} ->
        case refresh(auction) do
          :ok ->
            :ok

          _unavailable ->
            Logger.warning(
              "Payment history unavailable for auction #{auction.id}; retry scheduled"
            )

            :unavailable
        end

      _error ->
        :unavailable
    end
  end

  # Only the launches on the configured Base deployment's chain.
  defp claim(nil), do: {:ok, nil}

  defp claim(chain_id) do
    Repo.transaction(fn ->
      case Auction
           |> Ash.Query.for_read(:payments_due, %{chain_id: chain_id}, actor: @actor)
           |> Ash.read!() do
        [] ->
          nil

        [auction] ->
          Ash.update!(
            auction,
            %{payments_due_at: DateTime.add(DateTime.utc_now(), @retry_seconds)},
            action: :schedule_payments,
            actor: @actor
          )
      end
    end)
  end

  @doc "Reads one launch's next range of payments and commits it with the cursor."
  def refresh(auction) do
    with {:ok, config} <- Lab.current(),
         opts = LabRpc.opts(config, "revenue payments"),
         {:ok, head} <- Rpc.latest_block(opts),
         {:ok, launch} <- Pool.agent_launch(auction, config, head, opts),
         {:ok, assets} <- assets(auction, config, launch, head, opts),
         :ok <- cursor_valid(auction, head, opts),
         first = first_block(auction, launch, head),
         {:ok, last, logs} <-
           logs(launch.receiver, assets, first, min(first + @range - 1, head.number), opts),
         {:ok, headers} <- headers(logs, last, opts),
         {:ok, rows} <- rows(auction, config.chain_id, launch.receiver, assets, logs, headers),
         {:ok, current} <- header(head.number, opts),
         true <- current.hash == head.hash do
      commit(auction, first, last, headers[last].hash, rows, last == head.number)
    else
      # Graduated but not migrated yet: there is no receiver to read, and the
      # claim already put the next look a minute away.
      {:error, :not_graduated} -> :ok
      {:error, :cursor_changed} -> invalidate(auction)
      _unavailable -> {:error, :payments_unavailable}
    end
  end

  # The three assets the receiver takes, by lowercase address.
  defp assets(auction, config, launch, head, opts) do
    usdc = LabAbi.encode(Lab.abi!(config, :splitter), "usdc()", [])

    with {:ok, dollar} <- Rpc.call_address(launch.splitter, usdc, head, opts) do
      {:ok,
       %{
         String.downcase(dollar) => %{symbol: "USDC", decimals: 6},
         Lab.address!(config, :regent) => %{symbol: "REGENT", decimals: 18},
         String.downcase(launch.subject) => %{symbol: auction.token_symbol, decimals: 18}
       }}
    end
  end

  defp first_block(%{payments_next_block: next}, _launch, head) when is_integer(next),
    do: min(next, head.number)

  defp first_block(_auction, launch, head), do: min(launch.migration_block, head.number)

  defp cursor_valid(%{payments_next_block: nil}, _head, _opts), do: :ok

  defp cursor_valid(%{payments_next_block: next}, %{number: head}, _opts) when next > head + 1,
    do: {:error, :cursor_changed}

  defp cursor_valid(auction, _head, opts) do
    case header(auction.payments_next_block - 1, opts) do
      {:ok, %{hash: hash}} when hash == auction.payments_last_hash -> :ok
      {:ok, _other} -> {:error, :cursor_changed}
      _unavailable -> {:error, :history_unavailable}
    end
  end

  # The receiver's `PaymentRouted` records and, beside them, every transfer of
  # a taken asset into the receiver, which names who paid. A range with too
  # many records, or one the provider refuses, is halved.
  defp logs(receiver, assets, first, last, opts) do
    range = %{fromBlock: hex(first), toBlock: hex(last)}

    filters = [
      Map.merge(range, %{
        address: receiver,
        topics: [LabAbi.topic(LabAbi.payment_routed_signature())]
      }),
      Map.merge(range, %{
        address: Map.keys(assets),
        topics: [LabAbi.topic(@transfer), nil, address_topic(receiver)]
      })
    ]

    case map_ok(filters, &read_logs(&1, opts)) do
      {:ok, batches} ->
        rows = List.flatten(batches)

        if Enum.count_until(rows, @rows + 1) > @rows and first < last,
          do: logs(receiver, assets, first, div(first + last, 2), opts),
          else: {:ok, last, rows}

      _error when first < last ->
        logs(receiver, assets, first, div(first + last, 2), opts)

      error ->
        error
    end
  end

  defp read_logs(filter, opts) do
    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      _unavailable -> {:error, :logs_unavailable}
    end
  end

  defp header(number, opts) do
    with {:ok, %{"hash" => hash, "timestamp" => timestamp}} <-
           Rpc.request("eth_getBlockByNumber", [hex(number), false], opts),
         true <- Rpc.valid_hash?(hash),
         {:ok, seconds} <- quantity(timestamp) do
      {:ok, %{hash: String.downcase(hash), timestamp: seconds}}
    else
      _unavailable -> {:error, :header_unavailable}
    end
  end

  defp headers(logs, last, opts) do
    with {:ok, numbers} <- map_ok(logs, &quantity(&1["blockNumber"])) do
      (numbers ++ [last])
      |> Enum.uniq()
      |> Task.async_stream(&numbered_header(&1, opts),
        max_concurrency: 4,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {:ok, {number, value}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, number, value)}}
        _unavailable, _acc -> {:halt, {:error, :headers_unavailable}}
      end)
    end
  end

  defp numbered_header(number, opts) do
    with {:ok, value} <- header(number, opts), do: {:ok, {number, value}}
  end

  defp rows(auction, chain_id, receiver, assets, logs, headers) do
    with {:ok, positioned} <- map_ok(logs, &positioned(&1, headers)) do
      routed = LabAbi.topic(LabAbi.payment_routed_signature())
      {payments, transfers} = Enum.split_with(positioned, &(topic0(&1) == routed))

      map_ok(payments, fn payment ->
        row(auction, chain_id, receiver, assets, payment, transfers, headers)
      end)
    end
  end

  defp positioned(log, headers) do
    with false <- log["removed"],
         {:ok, number} <- quantity(log["blockNumber"]),
         {:ok, index} <- quantity(log["logIndex"]),
         true <- String.downcase(log["blockHash"]) == headers[number].hash,
         {:ok, words} <- words(log["data"]) do
      {:ok,
       %{
         block: number,
         index: index,
         transaction: String.downcase(log["transactionHash"]),
         address: String.downcase(log["address"]),
         topics: Enum.map(log["topics"], &String.downcase/1),
         words: words
       }}
    else
      _invalid -> {:error, :invalid_payment_event}
    end
  end

  defp row(auction, chain_id, receiver, assets, payment, transfers, headers) do
    with %{topics: [_topic, ref, _note, token_topic], words: [gross, _referral, net]} <- payment,
         {:ok, token} <- topic_address(token_topic),
         %{symbol: symbol, decimals: decimals} <- Map.get(assets, token) do
      {:ok,
       %{
         auction_id: auction.id,
         chain_id: chain_id,
         receiver: String.downcase(receiver),
         token: token,
         token_symbol: symbol,
         gross: exact(gross, decimals),
         net: exact(net, decimals),
         payer: payer(payment, token, gross, transfers),
         payment_ref: ref,
         transaction_hash: payment.transaction,
         log_index: payment.index,
         block_number: payment.block,
         block_hash: headers[payment.block].hash,
         occurred_at: DateTime.from_unix!(headers[payment.block].timestamp)
       }}
    else
      _invalid -> {:error, :invalid_payment_event}
    end
  end

  # A payment pulls exactly its amount into the receiver in the same
  # transaction, just before it is routed; that transfer names the payer. A
  # sweep routes a balance already waiting, so it has none.
  defp payer(payment, token, gross, transfers) do
    transfers
    |> Enum.filter(fn transfer ->
      transfer.transaction == payment.transaction and transfer.address == token and
        transfer.index < payment.index and transfer.words == [gross]
    end)
    |> Enum.max_by(& &1.index, fn -> nil end)
    |> case do
      %{topics: [_topic, from, _to]} ->
        {:ok, payer} = topic_address(from)
        payer

      nil ->
        nil
    end
  end

  # This system projection locks the launch's auction row before replacing
  # the confirmed rows of the range, so two passes never interleave.
  defp commit(auction, first, last, hash, rows, caught_up?) do
    Repo.transaction(fn ->
      current = locked(auction)

      if current.payments_next_block != auction.payments_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(
        from p in RevenuePayment,
          where: p.auction_id == ^auction.id and p.block_number >= ^first
      )

      Ash.bulk_create!(rows, RevenuePayment, :record, actor: @actor, return_errors?: true)

      Ash.update!(
        current,
        %{
          payments_next_block: last + 1,
          payments_last_hash: hash,
          payments_due_at:
            DateTime.add(DateTime.utc_now(), if(caught_up?, do: @caught_up_seconds, else: 1))
        },
        actor: @actor,
        action: :refresh_payments,
        return_notifications?: true
      )
    end)
    |> notified()
  end

  defp invalidate(auction) do
    Repo.transaction(fn ->
      current = locked(auction)

      if current.payments_next_block != auction.payments_next_block,
        do: Repo.rollback(:superseded)

      Repo.delete_all(from p in RevenuePayment, where: p.auction_id == ^auction.id)

      Ash.update!(
        current,
        %{payments_next_block: nil, payments_last_hash: nil, payments_due_at: DateTime.utc_now()},
        actor: @actor,
        action: :refresh_payments,
        return_notifications?: true
      )
    end)
    |> notified()
  end

  defp locked(auction) do
    Auction
    |> Ash.Query.for_read(:listed_by_id, %{id: auction.id}, actor: @actor)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!()
  end

  defp notified({:ok, {_updated, notifications}}) do
    Ash.Notifier.notify(notifications)
    :ok
  end

  defp notified(error), do: error

  # Whole units with every digit kept: 18 decimals can exceed what a rounded
  # decimal context holds.
  defp exact(atomic, decimals) do
    {:ok, shown} = Amounts.format_units(atomic, decimals)
    Decimal.new(shown)
  end

  defp topic0(%{topics: [topic | _rest]}), do: topic

  defp words("0x" <> data) when rem(byte_size(data), 64) == 0,
    do: map_ok(for(<<word::binary-size(64) <- data>>, do: word), &quantity("0x" <> &1))

  defp words(_data), do: {:error, :invalid_word}

  defp map_ok(items, read) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp quantity("0x" <> value) do
    case Integer.parse(value, 16) do
      {number, ""} -> {:ok, number}
      _invalid -> {:error, :invalid_quantity}
    end
  end

  defp quantity(_value), do: {:error, :invalid_quantity}

  defp hex(value), do: "0x" <> String.downcase(Integer.to_string(max(0, value), 16))

  defp topic_address("0x" <> word) do
    case Integer.parse(word, 16) do
      {value, ""} -> Abi.word_address(value)
      _invalid -> :error
    end
  end

  defp address_topic("0x" <> address),
    do: "0x" <> String.pad_leading(String.downcase(address), 64, "0")
end
