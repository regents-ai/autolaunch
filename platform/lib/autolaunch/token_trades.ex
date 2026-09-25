defmodule Autolaunch.TokenTrades do
  @moduledoc """
  A bounded, browser-independent projection of the trades in each launched
  token's pool. Each pass reads one token and at most 2,000 blocks of the
  PoolManager's `Swap` logs for that pool. The cursor and rows commit together;
  repeat ranges replace the same trades. A changed cursor block drops the
  token's trades and rebuilds them.
  """
  @behaviour Autolaunch.DurableWork.Handler
  import Ecto.Query
  require Ash.Query
  require Logger
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{LabAbi, Repo, Token, TokenTrade}
  @actor %System{}
  @swap "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
  @range 2_000
  @token_decimals 18
  @topic "token_trades"

  @doc "Every recorded trade arrives as `{:autolaunch_trade, token_id}`."
  def subscribe, do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, @topic)

  def poll(_, 0), do: []
  def poll(_, _), do: [:next]

  def handle(_context, :next) do
    case claim() do
      {:ok, nil} ->
        :ok

      {:ok, token} ->
        case refresh(token) do
          :ok ->
            :ok

          _ ->
            Logger.warning("Trades unavailable for token #{token.id}; retry scheduled")
            :unavailable
        end

      _ ->
        :unavailable
    end
  end

  defp claim do
    Repo.transaction(fn ->
      case Token |> Ash.Query.for_read(:trades_due, %{}, actor: @actor) |> Ash.read!() do
        [] ->
          nil

        [token] ->
          Ash.update!(token, %{trades_due_at: DateTime.add(DateTime.utc_now(), 60)},
            action: :schedule_trades,
            actor: @actor
          )
      end
    end)
  end

  def refresh(token) do
    with {:ok, venue} <- venue(token.auction),
         {:ok, head} <- Rpc.latest_block(venue.opts),
         {:ok, pool} <- swap_source(venue, token.auction, head),
         {:ok, first} <- first_block(token, pool, head, venue.opts),
         :ok <- cursor_valid(token, head, venue.opts),
         {:ok, last, logs} <- logs(pool, first, min(first + @range - 1, head.number), venue.opts),
         {:ok, headers} <- headers(logs, last, venue.opts),
         {:ok, trades} <- map_ok(logs, &trade(token, pool, headers, &1)) do
      trades = Enum.reject(trades, &is_nil/1)

      token
      |> commit(first, last, headers[last].hash, trades, last == head.number)
      |> indexed(token, trades, head.number - last)
    else
      {:error, :cursor_changed} -> invalidate(token)
      _ -> {:error, :trades_unavailable}
    end
  end

  # After a committed pass: how far the token's cursor trails the head, and
  # how long after its block each trade first seen by a pass that reached the
  # head from an existing cursor got to the site. A first pass or a rebuild
  # reads history rather than new trades, so it is left out.
  defp indexed(:ok, token, trades, behind) do
    chain_id = token.auction.chain_id

    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: behind},
      %{indexer: :token_trades, chain_id: chain_id}
    )

    if behind == 0 and is_integer(token.trades_next_block) do
      now = DateTime.utc_now()

      for %{block_number: number, occurred_at: at} <- trades,
          number >= token.trades_next_block,
          do:
            :telemetry.execute(
              [:autolaunch, :chain_event, :recorded],
              %{delay_ms: DateTime.diff(now, at, :millisecond)},
              %{kind: :trade, chain_id: chain_id}
            )
    end

    :ok
  end

  defp indexed(error, _token, _trades, _behind), do: error

  @doc """
  One `Swap` log's trade, in base units. The PoolManager reports each amount
  from the swapper's side: negative was paid into the pool, positive was taken
  out. The token coming out is a buy and going in is a sell; the currency
  amount is what the buyer paid or the seller received. `nil` for a swap that
  moved nothing on one side.
  """
  @spec decode_swap(map(), boolean()) ::
          {:ok, %{side: :buy | :sell, token: pos_integer(), currency: pos_integer()} | nil}
          | {:error, :invalid_swap}
  def decode_swap(%{"data" => "0x" <> data}, token_is_currency0?) do
    case Base.decode16(data, case: :mixed) do
      {:ok, <<amount0::signed-256, amount1::signed-256, _rest::binary-size(128)>>} ->
        {token, currency} =
          if token_is_currency0?, do: {amount0, amount1}, else: {amount1, amount0}

        cond do
          token == 0 or currency == 0 -> {:ok, nil}
          token > 0 -> {:ok, %{side: :buy, token: token, currency: -currency}}
          true -> {:ok, %{side: :sell, token: -token, currency: currency}}
        end

      _ ->
        {:error, :invalid_swap}
    end
  end

  def decode_swap(_log, _token_is_currency0?), do: {:error, :invalid_swap}

  defp venue(%{chain_id: chain, kind: kind}) do
    module =
      cond do
        Autolaunch.Robinhood.Lab.chain?(chain) -> Autolaunch.Robinhood.Lab
        kind == :stocks -> Autolaunch.Stocks.Lab
        true -> Autolaunch.Lab
      end

    with {:ok, config} <- module.current(),
         true <- config.chain_id == chain do
      opts =
        if module == Autolaunch.Lab,
          do: Autolaunch.LabRpc.opts(config, "token trades"),
          else: module.rpc_opts(config)

      {:ok, %{module: module, config: config, opts: opts}}
    end
  end

  defp swap_source(%{module: Autolaunch.Robinhood.Lab} = venue, auction, head),
    do:
      Autolaunch.Robinhood.Pool.swap_source(
        auction.auction_address,
        venue.config,
        head,
        venue.opts
      )

  defp swap_source(venue, auction, head),
    do: Autolaunch.Pool.swap_source(auction, venue.config, head, venue.opts)

  defp first_block(%{trades_next_block: next}, _, head, _) when is_integer(next),
    do: {:ok, min(next, head.number)}

  defp first_block(_, %{from_block: from}, head, _) when is_integer(from),
    do: {:ok, min(from, head.number)}

  # The Robinhood launch's migration block is on the rollup clock, so the
  # first pass starts where the launch deployed its auction, before the pool
  # could trade, and walks forward in the same bounded ranges as every other.
  defp first_block(token, _, head, opts),
    do: Rpc.deployment_block(token.auction.auction_address, head.number, opts)

  defp cursor_valid(%{trades_next_block: nil}, _, _), do: :ok

  defp cursor_valid(%{trades_next_block: next}, %{number: head}, _) when next > head + 1,
    do: {:error, :cursor_changed}

  defp cursor_valid(token, _, opts) do
    case header(token.trades_next_block - 1, opts) do
      {:ok, %{hash: hash}} when hash == token.trades_last_hash -> :ok
      {:ok, _} -> {:error, :cursor_changed}
      _ -> {:error, :history_unavailable}
    end
  end

  defp logs(pool, first, last, opts) do
    filter = %{
      address: pool.pool_manager,
      fromBlock: hex(first),
      toBlock: hex(last),
      topics: [LabAbi.topic(@swap), pool.pool_id]
    }

    case read_logs(filter, opts) do
      {:ok, rows} ->
        if Enum.count_until(rows, 201) > 200 and first < last,
          do: logs(pool, first, div(first + last, 2), opts),
          else: {:ok, last, rows}

      _ when first < last ->
        logs(pool, first, div(first + last, 2), opts)

      error ->
        error
    end
  end

  defp read_logs(filter, opts) do
    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, rows} when is_list(rows) -> {:ok, rows}
      _ -> {:error, :logs_unavailable}
    end
  end

  defp header(number, opts) do
    with {:ok, %{"hash" => hash, "timestamp" => timestamp}} <-
           Rpc.request("eth_getBlockByNumber", [hex(number), false], opts),
         true <- Rpc.valid_hash?(hash),
         {:ok, seconds} <- quantity(timestamp) do
      {:ok, %{hash: String.downcase(hash), timestamp: seconds}}
    else
      _ -> {:error, :header_unavailable}
    end
  end

  defp headers(logs, last, opts) do
    with {:ok, numbers} <- map_ok(logs, &quantity(&1["blockNumber"])) do
      (numbers ++ [last])
      |> Enum.uniq()
      |> Task.async_stream(
        &numbered_header(&1, opts),
        max_concurrency: 4,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, %{}}, fn
        {:ok, {:ok, {number, value}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, number, value)}}
        _, _ -> {:halt, {:error, :headers_unavailable}}
      end)
    end
  end

  defp numbered_header(number, opts) do
    with {:ok, value} <- header(number, opts), do: {:ok, {number, value}}
  end

  defp trade(token, pool, headers, log) do
    with false <- log["removed"],
         [_swap, id | _] <- log["topics"],
         true <- String.downcase(id) == String.downcase(pool.pool_id),
         {:ok, number} <- quantity(log["blockNumber"]),
         {:ok, index} <- quantity(log["logIndex"]),
         true <- String.downcase(log["blockHash"]) == headers[number].hash,
         {:ok, swap} <- decode_swap(log, pool.token_is_currency0?) do
      {:ok, swap && row(token, pool, headers[number], number, index, log, swap)}
    else
      _ -> {:error, :invalid_swap}
    end
  end

  defp row(token, pool, header, number, index, log, swap),
    do: %{
      token_id: token.id,
      transaction_hash: String.downcase(log["transactionHash"]),
      block_hash: header.hash,
      block_number: number,
      log_index: index,
      occurred_at: DateTime.from_unix!(header.timestamp),
      side: swap.side,
      currency_amount: Decimal.new(Rpc.format_units(swap.currency, pool.currency_decimals)),
      currency_symbol: pool.currency_symbol,
      token_amount: Decimal.new(Rpc.format_units(swap.token, @token_decimals))
    }

  # This system projection locks its token before replacing confirmed trades.
  # Only trades in blocks past the old cursor announce themselves, after the
  # transaction commits, so re-reading the head block stays quiet.
  defp commit(token, first, last, hash, trades, complete?) do
    Repo.transaction(fn ->
      current = locked(token)

      Repo.delete_all(
        from t in TokenTrade, where: t.token_id == ^token.id and t.block_number >= ^first
      )

      %{notifications: notifications} =
        Ash.bulk_create!(trades, TokenTrade, :record,
          actor: @actor,
          return_errors?: true,
          return_notifications?: true
        )

      Ash.update!(
        current,
        %{
          trades_next_block: last + 1,
          trades_last_hash: hash,
          trades_due_at: DateTime.add(DateTime.utc_now(), if(complete?, do: 5, else: 1))
        },
        actor: @actor,
        action: :refresh_trades
      )

      Enum.filter(notifications, &(&1.data.block_number >= (token.trades_next_block || 0)))
    end)
    |> case do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        :ok

      error ->
        error
    end
  end

  # Invalidation removes only this token's derived trades while holding the
  # token's lock; the next pass rebuilds them from the pool's logs.
  defp invalidate(token) do
    Repo.transaction(fn ->
      current = locked(token)
      Repo.delete_all(from t in TokenTrade, where: t.token_id == ^token.id)

      Ash.update!(
        current,
        %{trades_next_block: nil, trades_last_hash: nil, trades_due_at: DateTime.utc_now()},
        actor: @actor,
        action: :refresh_trades
      )
    end)
    |> case do
      {:ok, _token} -> :ok
      error -> error
    end
  end

  defp locked(token) do
    current =
      Token
      |> Ash.Query.for_read(:listed, %{}, actor: @actor)
      |> Ash.Query.filter(id == ^token.id)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!()

    if current.trades_next_block != token.trades_next_block,
      do: Repo.rollback(:superseded),
      else: current
  end

  defp map_ok(items, read) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp quantity("0x" <> value) do
    case Integer.parse(value, 16) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp quantity(_), do: {:error, :invalid_quantity}
  defp hex(value), do: "0x" <> Integer.to_string(max(0, value), 16)
end
