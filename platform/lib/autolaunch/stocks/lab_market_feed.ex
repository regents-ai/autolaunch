defmodule Autolaunch.Stocks.LabMarketFeed do
  @moduledoc """
  Polls the local fork every second for Stocks launches and their auctions.

  Two things happen per poll. Every `launches(id)` record the launchpad holds is
  projected into an `Auction` row when its launcher is a wallet this site's
  accounts hold and no row exists yet. Every Stocks auction row is then read
  from its own contract and the launchpad's lifecycle, and its state and
  clearing price are refreshed. Changes are broadcast on the shared market
  topic so open pages reload.
  """

  use GenServer

  require Ash.Query
  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.{LabAbi, LabProjection}
  alias Autolaunch.Stocks.{Amounts, Lab}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias Autolaunch.Stocks.LabProjection, as: StocksProjection

  @topic "autolaunch:lab_market"
  @interval 1_000
  @actor %System{}
  @new_decimals 18
  @lifecycle_index 11

  def topic, do: @topic

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @doc "The last accepted per-auction market readings, by lowercase auction address."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(options) do
    state = %{
      pubsub: Keyword.get(options, :pubsub, Autolaunch.PubSub),
      generation: 0,
      head: nil,
      snapshots: %{},
      in_flight: false,
      timer: nil
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       generation: state.generation,
       head: state.head,
       degraded?: false,
       auctions: state.snapshots
     }, state}
  end

  @impl true
  def handle_info(:poll, %{in_flight: false} = state) do
    parent = self()
    Task.start(fn -> send(parent, {:refreshed, safely(&refresh/0)}) end)
    {:noreply, %{state | in_flight: true, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(
        {:refreshed, {:ok, %{head: head, snapshots: snapshots, changed: changed}}},
        state
      ) do
    changed_ids =
      Enum.uniq(changed ++ changed_snapshot_ids(state.snapshots, snapshots))

    state =
      if changed_ids == [] and state.head == head do
        %{state | in_flight: false}
      else
        generation = state.generation + 1

        Phoenix.PubSub.broadcast(
          state.pubsub,
          @topic,
          {:autolaunch_market_updated,
           %{
             generation: generation,
             auction_ids: changed_ids,
             block_number: head.number,
             block_hash: head.hash
           }}
        )

        %{state | generation: generation, head: head, snapshots: snapshots, in_flight: false}
      end

    {:noreply, schedule(state, @interval)}
  end

  def handle_info({:refreshed, {:error, reason}}, state) do
    Logger.debug("stocks lab market feed skipped a poll: #{inspect(reason)}")
    {:noreply, schedule(%{state | in_flight: false}, @interval)}
  end

  # One poll: the launchpad's records, then every known Stocks auction.
  @doc false
  def refresh do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config, "autolaunch stocks market feed"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, projected} <- project_launches(config, block, opts),
         {:ok, auctions} <- Autolaunch.list_stocks_lab_market_auctions(actor: @actor),
         {:ok, snapshots, changed} <- refresh_auctions(config, block, opts, auctions) do
      {:ok, %{head: block, snapshots: snapshots, changed: projected ++ changed}}
    end
  end

  defp project_launches(config, block, opts) do
    with {:ok, next} <- launchpad_uint(config, "nextLaunchId()", [], block, opts) do
      Enum.reduce_while(0..(next - 1)//1, {:ok, []}, fn id, {:ok, changed} ->
        collect(project_launch(config, id, block, opts), changed)
      end)
    end
  end

  defp collect({:ok, nil}, changed), do: {:cont, {:ok, changed}}
  defp collect({:ok, auction_id}, changed), do: {:cont, {:ok, [auction_id | changed]}}
  defp collect({:error, reason}, _changed), do: {:halt, {:error, reason}}

  defp project_launch(config, id, block, opts) do
    with {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, launch} <- launch_record(record),
         auction_id <- LabProjection.auction_id(launch.auction),
         {:ok, nil} <- existing(auction_id),
         {:ok, %{id: account_id}} <- creator(launch.auction),
         %{} = lab_stock <- Lab.stock(config, launch.stock) || :unknown_stock,
         {:ok, name} <- erc20_string(launch.new_token, "name()", block, opts),
         {:ok, symbol} <- erc20_string(launch.new_token, "symbol()", block, opts),
         :ok <-
           StocksProjection.project_observed(%{
             auction_address: launch.auction,
             creator_human_account_id: account_id,
             title: name,
             summary: nil,
             token_symbol: String.slice(symbol, 0, 16),
             website: nil,
             image: nil,
             quote_token_address: launch.stock,
             quote_token_symbol: lab_stock.symbol,
             quote_token_decimals: lab_stock.decimals,
             state: :created,
             treasury_address: Lab.address!(config, :launchpad)
           }) do
      {:ok, auction_id}
    else
      {:error, reason} -> {:error, reason}
      _skipped -> {:ok, nil}
    end
  end

  # An empty record (a never-used id) has a zero token and is skipped.
  defp launch_record([launcher, new_token, stock, auction | _rest]) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, new_token} <- Abi.word_address(new_token),
         {:ok, stock} <- Abi.word_address(stock),
         {:ok, auction} <- Abi.word_address(auction) do
      {:ok, %{launcher: launcher, new_token: new_token, stock: stock, auction: auction}}
    end
  end

  defp launch_record(_record), do: :error

  defp existing(auction_id) do
    Autolaunch.Auction
    |> Ash.Query.for_read(:read, %{}, actor: @actor)
    |> Ash.Query.filter(id == ^auction_id)
    |> Ash.read_one(actor: @actor)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, _row} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a launch this server verified from one of its accounts' wallets is a
  # site-created auction; anything else on the launchpad is not listed.
  defp creator(auction) do
    case Autolaunch.get_verified_stocks_launch_by_auction(auction, actor: @actor) do
      {:ok, nil} -> {:ok, :unknown_creator}
      {:ok, %{human_account_id: account_id}} -> {:ok, %{id: account_id}}
      error -> error
    end
  end

  defp refresh_auctions(config, block, opts, auctions) do
    Enum.reduce_while(auctions, {:ok, %{}, []}, fn auction, {:ok, snapshots, changed} ->
      with {:ok, snapshot} <- market_snapshot(config, block, opts, auction),
           {:ok, changed_id} <- refresh_row(auction, snapshot) do
        {:cont,
         {:ok, Map.put(snapshots, snapshot.auction_address, snapshot),
          List.wrap(changed_id) ++ changed}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp market_snapshot(config, block, opts, auction) do
    address = auction.auction_address
    decimals = auction.quote_token_decimals

    with :ok <- Autolaunch.LabRpc.ensure_contract(address, block, opts),
         {:ok, start_block} <- auction_uint(config, address, "startBlock()", block, opts),
         {:ok, end_block} <- auction_uint(config, address, "endBlock()", block, opts),
         {:ok, claim_block} <- auction_uint(config, address, "claimBlock()", block, opts),
         {:ok, graduated?} <- auction_bool(config, address, "isGraduated()", block, opts),
         {:ok, clearing} <- auction_uint(config, address, "clearingPrice()", block, opts),
         {:ok, raised} <- auction_uint(config, address, "currencyRaised()", block, opts),
         {:ok, remaining} <- auction_uint(config, address, "remainingSupply()", block, opts),
         {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [address], block, opts),
         {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         market <- %{end_block: end_block, claim_block: claim_block},
         {:ok, positions} <- positions(config, auction, market, block, opts) do
      {:ok,
       %{
         auction_id: auction.id,
         auction_address: String.downcase(address),
         state:
           market_state(Enum.at(record, @lifecycle_index), graduated?, block.number, start_block),
         current_clearing_price: Amounts.format_cca_price(clearing, decimals, @new_decimals),
         block_number: block.number,
         block_hash: block.hash,
         start_block: start_block,
         end_block: end_block,
         claim_block: claim_block,
         currency_raised: Rpc.format_units(raised, decimals),
         currency_symbol: auction.quote_token_symbol,
         remaining_supply: Rpc.format_units(remaining, @new_decimals),
         graduated?: graduated?,
         positions: positions
       }}
    end
  end

  # After the end block, every site position of this auction is read back from
  # the auction's own `bids(bidId)` so its status follows the contract.
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

  defp refresh_row(auction, snapshot) do
    state = join_state(auction.state, snapshot.state)
    price = snapshot.current_clearing_price

    with {:ok, positions_changed?} <- Autolaunch.LabPositions.project(snapshot.positions) do
      cond do
        auction.state != state or auction.current_clearing_price != price ->
          # A graduation projects the public token row at once, so the pool page
          # exists as soon as the auction row says the launch graduated.
          with {:ok, row} <-
                 Autolaunch.refresh_lab_market_auction(auction, state, price, actor: @actor),
               :ok <- LabProjection.project_graduated_token(row),
               do: {:ok, auction.id}

        positions_changed? ->
          {:ok, auction.id}

        true ->
          {:ok, nil}
      end
    end
  end

  defp join_state(current, _observed) when current in [:graduated, :failed], do: current
  defp join_state(:active, :created), do: :active
  defp join_state(_current, observed), do: observed

  defp market_state(2, _graduated?, _block, _start), do: :graduated
  defp market_state(3, _graduated?, _block, _start), do: :failed
  defp market_state(_lifecycle, true, _block, _start), do: :graduated
  defp market_state(_lifecycle, _graduated?, block, start) when block >= start, do: :active
  defp market_state(_lifecycle, _graduated?, _block, _start), do: :created

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      count,
      opts
    )
  end

  defp auction_uint(config, address, signature, block, opts),
    do:
      Rpc.call_uint(
        address,
        LabAbi.encode(Lab.abi!(config, :auction), signature, []),
        block,
        opts
      )

  defp auction_bool(config, address, signature, block, opts),
    do:
      Rpc.call_bool(
        address,
        LabAbi.encode(Lab.abi!(config, :auction), signature, []),
        block,
        opts
      )

  # `name()` and `symbol()` return one ABI string: offset, length, bytes.
  defp erc20_string(token, signature, block, opts) do
    case Rpc.request(
           "eth_call",
           [
             %{to: token, data: LabAbi.selector(signature)},
             %{blockHash: block.hash, requireCanonical: true}
           ],
           opts
         ) do
      {:ok, "0x" <> hex} when byte_size(hex) >= 128 ->
        with {:ok, [_offset, length | _rest]} <-
               LabAbi.decode_words("0x" <> binary_part(hex, 0, 128)),
             true <- byte_size(hex) >= 128 + length * 2,
             {:ok, bytes} <- Base.decode16(binary_part(hex, 128, length * 2), case: :mixed),
             true <- String.valid?(bytes) do
          {:ok, bytes}
        else
          _unreadable -> {:error, :invalid_chain_response}
        end

      {:ok, _other} ->
        {:error, :invalid_chain_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp changed_snapshot_ids(previous, current) do
    for {address, snapshot} <- current,
        Map.get(previous, address) != snapshot,
        do: snapshot.auction_id
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  defp safely(callback) do
    callback.()
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
