defmodule Autolaunch.LabMarketFeed do
  @moduledoc false

  use GenServer

  require Logger

  alias __MODULE__.{Projector, Reader}

  @topic "autolaunch:lab_market"
  # A lab moves every second; a mainnet reading is fresh enough every fifteen.
  @lab_delay 1_000
  @mainnet_delay 15_000
  @max_delay 10_000

  def topic, do: @topic

  def start_link(options \\ []) do
    case Keyword.get(options, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def refresh(server \\ __MODULE__) do
    send(server, :poll)
    :ok
  end

  @impl true
  def init(options) do
    state = %{
      reader: Keyword.get(options, :reader, Reader),
      projector: Keyword.get(options, :projector, Projector),
      pubsub: Keyword.get(options, :pubsub, Autolaunch.PubSub),
      poll?: Keyword.get(options, :poll?, true),
      delay: Keyword.get(options, :initial_delay, initial_delay()),
      generation: 0,
      watch: Autolaunch.MarketWatch.new(),
      binding: nil,
      accepted_head: nil,
      failed_head: nil,
      attempted_head: nil,
      attempted_addresses: MapSet.new(),
      pending_projection: nil,
      displaced_head: nil,
      recovery_head: nil,
      snapshots: %{},
      degraded?: false,
      in_flight: nil,
      timer: nil
    }

    {:ok, if(state.poll?, do: schedule(state, 0), else: state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       generation: state.generation,
       head: state.accepted_head,
       degraded?: state.degraded?,
       auctions: state.snapshots
     }, state}
  end

  @impl true
  def handle_info(:poll, %{in_flight: nil} = state) do
    token = make_ref()
    parent = self()
    reader = state.reader

    Task.start(fn -> send(parent, {:head, token, safely(fn -> reader.head() end)}) end)

    {:noreply, %{state | in_flight: %{token: token, stage: :head}, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:head, token, result}, %{in_flight: %{token: token, stage: :head}} = state) do
    case result do
      {:ok, head} ->
        handle_head(state, head)

      {:error, reason} ->
        Logger.warning("revstake market feed could not read the chain head: #{inspect(reason)}")
        {:noreply, failed(%{state | in_flight: nil})}
    end
  end

  def handle_info({:head, _token, _result}, state), do: {:noreply, state}

  def handle_info(
        {:snapshots, token, result},
        %{in_flight: %{token: token, stage: :snapshots, head: head}} = state
      ) do
    case result do
      {:ok, refresh} ->
        finish_refresh(%{state | watch: refresh.watch}, head, refresh)

      {:error, reason} ->
        Logger.warning("revstake market feed could not read its auctions: #{inspect(reason)}")
        {:noreply, failed_exact_head(state, head, state.attempted_addresses)}
    end
  end

  def handle_info({:snapshots, _token, _result}, state), do: {:noreply, state}

  def handle_info(
        {:projected, token, outcome},
        %{in_flight: %{token: token, stage: :projection, head: head, snapshots: snapshots}} =
          state
      ),
      do: handle_projection(outcome, state, head, snapshots)

  def handle_info({:projected, _token, _outcome}, state), do: {:noreply, state}

  defp handle_head(state, head) do
    state = discard_displaced_pending(state, head)

    cond do
      state.binding && state.binding != head.binding ->
        state
        |> invalidate_for(head)
        |> begin_snapshots(head)

      pending_for_head?(state, head) ->
        project_refresh(state, head, state.pending_projection.snapshots)

      recovery_for_head?(state, head) ->
        begin_snapshots(%{state | recovery_head: nil}, head)

      recovery_not_advanced?(state, head) ->
        {:noreply, failed(%{state | in_flight: nil})}

      displaced_for_head?(state, head) ->
        {:noreply, failed(%{state | in_flight: nil})}

      accepted_head_displaced?(state, head) ->
        {:noreply, displace_cache(state, head)}

      true ->
        begin_snapshots(%{state | binding: head.binding}, head)
    end
  end

  defp begin_snapshots(state, head) do
    token = make_ref()
    parent = self()
    reader = state.reader
    attempted_addresses = attempted_addresses(state, head)
    watch = state.watch

    Task.start(fn ->
      send(
        parent,
        {:snapshots, token, safely(fn -> reader.snapshots(head, watch, attempted_addresses) end)}
      )
    end)

    {:noreply,
     %{
       state
       | in_flight: %{token: token, stage: :snapshots, head: head},
         attempted_head: %{binding: head.binding, block: head.block},
         attempted_addresses: attempted_addresses,
         timer: nil
     }}
  end

  defp finish_refresh(state, head, %{snapshots: snapshots, attempted: attempted_addresses}) do
    state = %{state | attempted_addresses: attempted_addresses}

    cond do
      failed_for_head?(state, head) ->
        {:noreply, failed(%{state | in_flight: nil})}

      same_head?(state.accepted_head, head.block) and snapshots == [] and
          not state.degraded? ->
        {:noreply, finish_unchanged_head(state, head)}

      true ->
        project_refresh(state, head, snapshots)
    end
  end

  # Verifying the head and writing the readings both reach the chain or the
  # database, so they run in a task: a page asking for the snapshot is always
  # answered at once from the last accepted readings.
  defp project_refresh(state, head, snapshots) do
    token = make_ref()
    parent = self()
    %{reader: reader, projector: projector} = state

    Task.start(fn ->
      send(parent, {:projected, token, projection(reader, projector, head, snapshots)})
    end)

    {:noreply,
     %{state | in_flight: %{token: token, stage: :projection, head: head, snapshots: snapshots}}}
  end

  # The head is verified before the readings are written and again after, so
  # nothing is published from a block the chain has since left.
  defp projection(reader, projector, head, snapshots) do
    with :ok <- safely(fn -> reader.verify_head(head) end),
         {:ok, durable_changed_ids} <- safely(fn -> projector.project(snapshots) end),
         :ok <- safely(fn -> reader.verify_head(head) end) do
      {:ok, durable_changed_ids}
    end
  end

  defp handle_projection({:ok, durable_changed_ids}, state, head, snapshots),
    do: accept_refresh(state, head, snapshots, durable_changed_ids)

  defp handle_projection({:error, {:head_changed, current}}, state, _head, _snapshots),
    do: {:noreply, verified_transition(state, current)}

  defp handle_projection({:error, reason}, state, head, snapshots) do
    Logger.warning("revstake market feed could not record its readings: #{inspect(reason)}")
    {:noreply, retry_projection(state, head, snapshots)}
  end

  # A pass reads only part of the auctions, so its readings join the ones
  # earlier passes accepted; each reading names the block it was taken at. A
  # head the chain left clears them all (`displace_cache/2`, `invalidate_for/2`).
  defp accept_refresh(state, head, snapshots, durable_changed_ids) do
    next_snapshots = Map.merge(state.snapshots, Map.new(snapshots, &{&1.auction_address, &1}))

    cache_changed_ids = changed_snapshot_ids(state.snapshots, next_snapshots)
    changed_ids = Enum.uniq(durable_changed_ids ++ cache_changed_ids)

    status_changed? =
      state.binding != head.binding or not same_head?(state.accepted_head, head.block) or
        state.degraded?

    notify? = status_changed? or changed_ids != []
    generation = if notify?, do: state.generation + 1, else: state.generation

    if notify?, do: broadcast(state, generation, changed_ids, head.block)

    {:noreply,
     succeeded(%{
       state
       | generation: generation,
         binding: head.binding,
         accepted_head: head.block,
         failed_head: nil,
         pending_projection: nil,
         displaced_head: nil,
         recovery_head: nil,
         snapshots: next_snapshots,
         degraded?: false,
         in_flight: nil
     })}
  end

  defp invalidate_for(state, head) do
    generation = state.generation + 1
    broadcast_invalidation(state, generation, head.block)

    %{
      state
      | generation: generation,
        binding: head.binding,
        accepted_head: nil,
        failed_head: nil,
        attempted_head: nil,
        attempted_addresses: MapSet.new(),
        pending_projection: nil,
        displaced_head: head_identity(head),
        recovery_head: nil,
        snapshots: %{},
        degraded?: true,
        in_flight: nil
    }
  end

  defp failed_exact_head(state, head, attempted_addresses) do
    failed(%{
      state
      | failed_head: %{binding: head.binding, block: head.block},
        attempted_head: %{binding: head.binding, block: head.block},
        attempted_addresses: attempted_addresses,
        pending_projection: nil,
        in_flight: nil
    })
  end

  defp displace_cache(state, head) do
    generation = state.generation + 1
    broadcast_invalidation(state, generation, head.block)

    state
    |> Map.merge(%{
      generation: generation,
      failed_head: nil,
      attempted_head: nil,
      attempted_addresses: MapSet.new(),
      pending_projection: nil,
      displaced_head: head_identity(head),
      recovery_head: nil,
      snapshots: %{},
      degraded?: true,
      in_flight: nil
    })
    |> failed()
  end

  defp retry_projection(state, head, snapshots) do
    state
    |> Map.put(:pending_projection, %{
      binding: head.binding,
      block: head.block,
      snapshots: snapshots
    })
    |> Map.put(:in_flight, nil)
    |> failed()
  end

  defp verified_transition(state, current) do
    cond do
      state.binding && state.binding != current.binding ->
        state
        |> invalidate_for(current)
        |> Map.put(:recovery_head, head_identity(current))
        |> failed()

      recovery_not_advanced?(state, current) ->
        state
        |> Map.merge(%{
          failed_head: nil,
          pending_projection: nil,
          displaced_head: head_identity(current),
          recovery_head: nil,
          in_flight: nil
        })
        |> failed()

      moved_sideways?(state.accepted_head, current.block) or
          moved_backwards?(state.accepted_head, current.block) ->
        displace_cache(state, current)

      true ->
        state
        |> Map.merge(%{
          failed_head: nil,
          attempted_head: nil,
          attempted_addresses: MapSet.new(),
          pending_projection: nil,
          displaced_head: nil,
          recovery_head: nil,
          in_flight: nil
        })
        |> failed()
    end
  end

  defp broadcast(state, generation, changed_ids, block) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:autolaunch_market_updated,
       %{
         generation: generation,
         auction_ids: changed_ids,
         block_number: block.number,
         block_hash: block.hash
       }}
    )
  end

  defp broadcast_invalidation(state, generation, block) do
    changed_ids = state.snapshots |> Map.values() |> Enum.map(& &1.auction_id) |> Enum.uniq()

    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:autolaunch_market_updated,
       %{
         generation: generation,
         auction_ids: changed_ids,
         block_number: block.number,
         block_hash: block.hash,
         invalidated?: true
       }}
    )
  end

  defp pending_for_head?(
         %{pending_projection: %{binding: binding, block: block}},
         %{binding: binding, block: block}
       ),
       do: true

  defp pending_for_head?(_state, _head), do: false

  defp pending_displaced_by?(
         %{pending_projection: %{binding: binding, block: pending}},
         %{binding: binding, block: observed}
       ),
       do: moved_sideways?(pending, observed) or moved_backwards?(pending, observed)

  defp pending_displaced_by?(_state, _head), do: false

  defp discard_displaced_pending(state, head) do
    if pending_displaced_by?(state, head), do: %{state | pending_projection: nil}, else: state
  end

  defp accepted_head_displaced?(state, head) do
    moved_sideways?(state.accepted_head, head.block) or
      moved_backwards?(state.accepted_head, head.block)
  end

  defp displaced_for_head?(%{displaced_head: displaced}, head),
    do: displaced == head_identity(head)

  defp recovery_for_head?(%{recovery_head: recovery}, head),
    do: recovery == head_identity(head)

  defp recovery_not_advanced?(
         %{
           degraded?: true,
           accepted_head: nil,
           attempted_head: %{binding: binding, block: %{number: attempted_number}}
         },
         %{binding: binding, block: %{number: current_number}}
       ),
       do: current_number <= attempted_number

  defp recovery_not_advanced?(_state, _head), do: false

  defp head_identity(head), do: %{binding: head.binding, block: head.block}

  defp finish_unchanged_head(state, _head), do: succeeded(%{state | in_flight: nil})

  defp attempted_addresses(
         %{attempted_head: %{binding: binding, block: block}, attempted_addresses: attempted},
         %{binding: binding, block: block}
       ),
       do: attempted

  defp attempted_addresses(_state, _head), do: MapSet.new()

  defp failed_for_head?(
         %{failed_head: %{binding: binding, block: block}},
         %{binding: binding, block: block}
       ),
       do: true

  defp failed_for_head?(_state, _head), do: false

  defp same_head?(%{number: number, hash: hash}, %{number: number, hash: hash}), do: true
  defp same_head?(_accepted, _observed), do: false

  defp moved_sideways?(%{number: number, hash: old}, %{number: number, hash: new}),
    do: old != new

  defp moved_sideways?(_accepted, _observed), do: false

  defp moved_backwards?(%{number: accepted}, %{number: observed}), do: observed < accepted
  defp moved_backwards?(_accepted, _observed), do: false

  defp changed_snapshot_ids(previous, current) do
    current
    |> Enum.reduce([], fn {address, snapshot}, changed ->
      if Map.get(previous, address) == snapshot,
        do: changed,
        else: [snapshot.auction_id | changed]
    end)
    |> Enum.reverse()
  end

  defp succeeded(state) do
    delay = initial_delay()

    state
    |> Map.put(:delay, delay)
    |> schedule(delay)
  end

  defp failed(state) do
    delay = min(max(state.delay * 2, 2_000), max(@max_delay, initial_delay()))
    state |> Map.put(:delay, delay) |> schedule(delay)
  end

  defp initial_delay, do: if(Autolaunch.Lab.test_chain?(), do: @lab_delay, else: @mainnet_delay)

  defp schedule(%{poll?: false} = state, _delay), do: state

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  defp safely(callback) do
    callback.()
  rescue
    _error -> {:error, :market_feed_unavailable}
  catch
    _kind, _reason -> {:error, :market_feed_unavailable}
  end

  defmodule Reader do
    @moduledoc false

    require Logger

    @read_concurrency 8
    @read_timeout 10_000

    alias Autolaunch.Auction.MarketState
    alias Autolaunch.Chain.Rpc
    alias Autolaunch.{Lab, LabRpc, MarketWatch}

    def head do
      with {:ok, config, block, opts} <- LabRpc.current([:strategy]) do
        {:ok, %{config: config, binding: Lab.full_binding(config), block: block, rpc_opts: opts}}
      end
    end

    def verify_head(expected) do
      case head() do
        {:ok, current} ->
          if current.binding == expected.binding and current.block == expected.block,
            do: :ok,
            else: {:error, {:head_changed, current}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def snapshots(head, watch, attempted_addresses) do
      with {:ok, auctions, next_watch} <- MarketWatch.next(watch, Lab.chain_id(), :agent) do
        observed_addresses = MapSet.new(auctions, &String.downcase(&1.auction_address))

        pending =
          Enum.reject(auctions, fn auction ->
            MapSet.member?(attempted_addresses, String.downcase(auction.auction_address))
          end)

        {:ok,
         %{
           snapshots: collect_snapshots(pending, head),
           attempted: MapSet.union(attempted_addresses, observed_addresses),
           watch: next_watch
         }}
      end
    end

    # Each auction is read on its own: one that cannot be read is logged and
    # left as it is, and every other auction still refreshes.
    defp collect_snapshots(auctions, head) do
      auctions
      |> Task.async_stream(&{&1, snapshot(head, &1)},
        max_concurrency: @read_concurrency,
        ordered: false,
        timeout: @read_timeout,
        on_timeout: :kill_task,
        zip_input_on_exit: true
      )
      |> Enum.flat_map(&collect_snapshot/1)
    end

    defp collect_snapshot({:ok, {_auction, {:ok, snapshot}}}), do: [snapshot]

    # A row whose contract does not exist at this head has no market to read
    # (a launch mined on another lab run, or one a reorg removed).
    defp collect_snapshot({:ok, {_auction, {:error, :lab_contract_missing}}}), do: []

    defp collect_snapshot({:ok, {auction, {:error, reason}}}), do: skipped(auction, reason)
    defp collect_snapshot({:exit, {auction, reason}}), do: skipped(auction, reason)

    defp skipped(auction, reason) do
      Logger.warning(
        "revstake market feed skipped auction #{auction.auction_address}: #{inspect(reason)}"
      )

      []
    end

    defp snapshot(%{config: config, block: block, rpc_opts: opts}, auction) do
      address = auction.auction_address

      with :ok <- LabRpc.ensure_contract(address, block, opts),
           {:ok, start_block} <- call_uint(config, address, "startBlock()", block, opts),
           {:ok, end_block} <- call_uint(config, address, "endBlock()", block, opts),
           {:ok, claim_block} <- call_uint(config, address, "claimBlock()", block, opts),
           {:ok, minimum_reached} <- call_bool(config, address, "isGraduated()", block, opts),
           {:ok, clearing_price} <- call_uint(config, address, "clearingPrice()", block, opts),
           {:ok, currency_raised} <- call_uint(config, address, "currencyRaised()", block, opts),
           {:ok, remaining_supply} <- call_uint(config, address, "remainingSupply()", block, opts),
           {:ok, distribution} <-
             LabRpc.words(
               config,
               :strategy,
               "distribution(address)",
               [address],
               18,
               block,
               opts
             ),
           {:ok, price_quote} <-
             Autolaunch.Pool.agent_price_quote(config, distribution, block, opts) do
        lifecycle = Enum.at(distribution, 0)
        market = %{end_block: end_block, claim_block: claim_block}

        with {:ok, positions} <- positions(config, auction, market, block, opts) do
          {:ok,
           %{
             auction_id: auction.id,
             auction_address: String.downcase(address),
             state: MarketState.observed(lifecycle, block.number, start_block, end_block),
             current_clearing_price: Lab.format_price(clearing_price),
             price_quote: price_quote,
             block_number: block.number,
             block_hash: block.hash,
             start_block: start_block,
             end_block: end_block,
             claim_block: claim_block,
             currency_raised: Rpc.format_units(currency_raised, 18),
             remaining_supply: Rpc.format_units(remaining_supply, 18),
             minimum_reached: minimum_reached,
             pool_id: pool_id(Enum.at(distribution, 16)),
             positions: positions
           }}
        end
      end
    end

    # After the end block, every site position of this auction is read back
    # from the auction's own `bids(bidId)` so its status follows the contract.
    defp positions(config, auction, market, block, opts) do
      if block.number >= market.end_block do
        with {:ok, rows} <- Autolaunch.LabPositions.positions(auction.id) do
          Autolaunch.LabPositions.read(
            Lab.abi!(config, :auction),
            rows,
            auction.auction_address,
            market,
            block,
            opts
          )
        end
      else
        {:ok, []}
      end
    end

    defp call_uint(config, address, signature, block, opts),
      do: LabRpc.call_uint(config, address, "auction", signature, [], block, opts)

    defp call_bool(config, address, signature, block, opts) do
      Autolaunch.Chain.Rpc.call_bool(
        address,
        Autolaunch.LabAbi.encode(config.abis["auction"], signature, []),
        block,
        opts
      )
    end

    defp pool_id(0), do: nil

    defp pool_id(value) when is_integer(value) and value > 0 do
      "0x" <>
        (value
         |> :binary.encode_unsigned()
         |> Base.encode16(case: :lower)
         |> String.pad_leading(64, "0"))
    end
  end

  defmodule Projector do
    @moduledoc false

    require Logger

    alias Autolaunch
    alias Autolaunch.Actors.System, as: SystemActor
    alias Autolaunch.Auction
    alias Autolaunch.Auction.MarketState

    @doc """
    Writes one pass's readings and returns the ids of the auctions whose rows
    changed. Each auction is written in its own Ash transaction: its
    positions, market fields, token and token price land together or not at
    all, and pages hear of them once they are committed. An auction whose
    write fails is logged and left as it was; every other auction still
    refreshes.
    """
    def project(snapshots) do
      actor = %SystemActor{}

      {:ok,
       snapshots
       |> Enum.sort_by(& &1.auction_id)
       |> Enum.flat_map(&project_snapshot(&1, actor))}
    end

    defp project_snapshot(snapshot, actor) do
      case Ash.transaction(Auction, fn -> commit(write_snapshot(snapshot, actor)) end) do
        {:ok, true} ->
          [snapshot.auction_id]

        {:ok, false} ->
          []

        {:error, error} ->
          Logger.warning(
            "revstake market feed skipped auction #{snapshot.auction_address}: #{inspect(error)}"
          )

          []
      end
    end

    defp write_snapshot(snapshot, actor) do
      case Autolaunch.get_lab_market_auction_for_update(snapshot.auction_id, actor: actor) do
        {:ok, %Auction{} = auction} -> refresh_snapshot(auction, snapshot, actor)
        {:ok, nil} -> {:error, :lab_auction_not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    defp refresh_snapshot(auction, snapshot, actor) do
      market = %{
        state: MarketState.join(auction.state, snapshot.state),
        price: snapshot.current_clearing_price,
        minimum_reached: snapshot.minimum_reached
      }

      market_changed? =
        auction.state != market.state or auction.current_clearing_price != market.price or
          auction.minimum_reached != market.minimum_reached

      with {:ok, positions_changed?} <- Autolaunch.LabPositions.project(snapshot.positions),
           :ok <- refresh_market(auction, market_changed?, market, actor),
           {:ok, price_changed?} <-
             Autolaunch.LabProjection.project_token_price(auction.id, snapshot.price_quote) do
        {:ok, market_changed? or positions_changed? or price_changed?}
      end
    end

    # A launch the feed sees graduate becomes a public token in the same
    # transaction, so its pool page exists as soon as the auction says so, and
    # the token's price is the pool's from the same reading.
    defp refresh_market(_auction, false, _market, _actor), do: :ok

    defp refresh_market(auction, true, market, actor) do
      with {:ok, refreshed} <-
             Autolaunch.refresh_lab_market_auction(
               auction,
               market.state,
               market.price,
               %{minimum_reached: market.minimum_reached},
               actor: actor
             ),
           do: Autolaunch.LabProjection.project_graduated_token(refreshed)
    end

    defp commit({:ok, value}), do: value
    defp commit({:error, reason}), do: Ash.DataLayer.rollback(Auction, reason)
  end
end
