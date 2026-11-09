defmodule Autolaunch.LaunchDiscovery.Discover do
  @moduledoc """
  Records every Base launch created since the last run, Revstake and Memestock,
  with the transaction that created it, read at the latest block.

  Each launchpad numbers its launches (`nextLaunchId`), so a run reads the
  highest id and records each id above the highest one recorded, in order. A
  launch's auction opens a fixed number of blocks after the block it was
  created in, so its creation log, and with it the transaction, is read from
  that one block by its launch id:

  - Revstake: the factory's `launches(id)` names the launcher and auction, the
    strategy's `distribution(auction)` its start block, and the strategy's
    `START_DELAY_BLOCKS()` the delay; the log is the factory's `LaunchCreated`.
  - Memestock: the launchpad's `launches(id)` names the launcher, auction and
    start block, `START_LEAD_BLOCKS` (300, in `StocksPreset.sol`) before which
    the launchpad's `StockLaunchCreated` was emitted.

  It runs every five minutes, and at once when a press on a chain with a Base
  launchpad lands (`Autolaunch.ChainRefresh`), so a creator's own launch is
  listed straight away. A run that recorded every launch up to the head sends
  the chain readers' `[:autolaunch, :indexer, :lag]` event for each launchpad,
  so launches the counter shows and the site has not recorded show as passes
  that stop. A run that recorded a new launch has the count the pages read
  taken again (`Autolaunch.LaunchDiscovery.Count`), so their catching-up
  notice clears.
  """

  @behaviour Autolaunch.ChainRefresh

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, LaunchAbi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.LaunchDiscovery.Count
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @launchpads [:base_revstake, :base_memestock]
  @start_lead_blocks 300

  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl true
  def refresh(chain_id) do
    if not Autolaunch.Prelaunch.read_only?() and
         Enum.any?(launchpads(), &(&1.chain_id == chain_id)),
       do: AshOban.schedule(Autolaunch.LaunchDiscovery, :discover)

    :ok
  end

  def run(_input, _context) do
    Enum.reduce_while(launchpads(), :ok, fn pad, :ok ->
      case discover(pad) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "The Base launchpads this site discovers launches on."
  def launchpads, do: Enum.filter(Launchpads.configured(), &(&1.launchpad in @launchpads))

  @doc """
  The latest block, the highest launch id `pad` has made at it, and the highest
  one the site has recorded.
  """
  @spec standing(map()) ::
          {:ok, %{block: map(), made: non_neg_integer(), recorded: non_neg_integer()}}
          | {:error, term()}
  def standing(pad) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, made} <- Launchpads.last_launch_id(pad, block),
         {:ok, recorded} <- known(pad),
         do: {:ok, %{block: block, made: made, recorded: recorded}}
  end

  defp discover(pad) do
    with {:ok, %{block: block, made: made, recorded: recorded}} <- standing(pad),
         :ok <- record_new(pad, (recorded + 1)..made//1, block) do
      if made > recorded, do: Count.read_again()
      followed(pad)
    end
  end

  defp record_new(pad, launch_ids, block) do
    Enum.reduce_while(launch_ids, :ok, fn launch_id, :ok ->
      case record(pad, launch_id, block) do
        {:ok, _discovery} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Every launch up to the head it read is recorded, so it trails the chain by
  # nothing, as the site's other chain readers say once a pass is done.
  defp followed(pad) do
    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: 0},
      %{indexer: :launch_discovery, chain_id: pad.chain_id}
    )
  end

  defp known(pad) do
    case Autolaunch.latest_launch_discovery(pad.chain_id, pad.contract, actor: %System{}) do
      {:ok, nil} -> {:ok, 0}
      {:ok, discovery} -> {:ok, discovery.launch_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(pad, launch_id, block) do
    with {:ok, launch} <- created(pad, launch_id, block),
         {:ok, hash} <- creation_transaction(pad, launch_id, launch.created_block) do
      Autolaunch.record_launch_discovery(
        %{
          launchpad: pad.launchpad,
          chain_id: pad.chain_id,
          contract: pad.contract,
          launch_id: launch_id,
          launcher: launch.launcher,
          auction: launch.auction,
          transaction_hash: hash
        },
        actor: %System{}
      )
    end
  end

  defp created(%{launchpad: :base_revstake} = pad, launch_id, block) do
    with {:ok, [launcher, _subject, auction | _rest]} <-
           words(pad.contract, pad.abi, "launches(uint256)", [launch_id], 5, block, pad),
         {:ok, launcher} <- address(launcher),
         {:ok, auction} <- address(auction),
         {:ok, distribution} <-
           words(
             pad.strategy,
             pad.strategy_abi,
             "distribution(address)",
             [auction],
             LabAbi.distribution_words(),
             block,
             pad
           ),
         {:ok, [delay]} <-
           words(pad.strategy, pad.strategy_abi, "START_DELAY_BLOCKS()", [], 1, block, pad) do
      start_block = LabAbi.distribution(distribution).start_block
      {:ok, %{launcher: launcher, auction: auction, created_block: start_block - delay}}
    end
  end

  defp created(%{launchpad: :base_memestock} = pad, launch_id, block) do
    with {:ok, [launcher, _token, _stock, auction, _splitter, start_block | _rest]} <-
           words(
             pad.contract,
             pad.abi,
             "launches(uint256)",
             [launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             pad
           ),
         {:ok, launcher} <- address(launcher),
         {:ok, auction} <- address(auction) do
      {:ok,
       %{launcher: launcher, auction: auction, created_block: start_block - @start_lead_blocks}}
    end
  end

  defp creation_transaction(pad, launch_id, created_block) do
    filter = %{
      address: pad.contract,
      fromBlock: quantity(created_block),
      toBlock: quantity(created_block),
      topics: [launch_created(pad), word(launch_id)]
    }

    case Rpc.request("eth_getLogs", [filter], pad.opts) do
      {:ok, [%{"transactionHash" => hash}]} when is_binary(hash) ->
        {:ok, String.downcase(hash)}

      {:ok, _logs} ->
        {:error, {:launch_log_not_found, launch_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp launch_created(%{launchpad: :base_revstake}), do: LaunchAbi.selector(:launch_created)

  defp launch_created(%{launchpad: :base_memestock}),
    do: Abi.topic0(StocksLabAbi.launch_created_signature())

  defp words(to, abi, signature, arguments, count, block, pad),
    do: Rpc.call_words(to, LabAbi.encode(abi, signature, arguments), block, count, pad.opts)

  defp address(word) do
    case Abi.word_address(word) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_chain_response}
    end
  end

  defp quantity(number), do: "0x" <> String.downcase(Integer.to_string(number, 16))

  defp word(number),
    do: "0x" <> String.pad_leading(String.downcase(Integer.to_string(number, 16)), 64, "0")
end
