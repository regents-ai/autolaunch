defmodule Autolaunch.LaunchDiscovery.Discover do
  @moduledoc """
  Records every Base launch the site has not recorded yet, Revstake and
  Memestock, with the transaction that created it, read at the latest block.

  Each launchpad numbers its launches (`nextLaunchId`), so a run reads the
  highest id and records each id up to it that has no record, in order. A
  launch that cannot be read or recorded is one warning line and is left out:
  the launches after it, and the other launchpad, are still recorded. A
  launchpad whose head or count cannot be read is left out the same way. The
  run then fails naming each one, and the next run reads them again. A
  launch's auction opens a fixed number of blocks after the block it was
  created in, so its creation log, and with it the transaction, is read from
  that one block by its launch id:

  - Revstake: the factory's `launches(id)` names the launcher and auction, the
    strategy's `distribution(auction)` its start block, and the strategy's
    `START_DELAY_BLOCKS()` the delay; the log is the factory's `LaunchCreated`.
  - Memestock: the launchpad's `launches(id)` names the launcher, auction and
    start block, the launchpad version's `START_LEAD_BLOCKS` (in its
    `StocksPreset.sol`; `Autolaunch.Stocks.LaunchActions.schedule/2`) before
    which the launchpad's `StockLaunchCreated` was emitted. The launchpad does
    not answer its lead, so it is the one figure read from the site's own
    copy of the preset.

  It runs every five minutes, and at once when a press on a chain with a Base
  launchpad lands (`Autolaunch.ChainRefresh`), so a creator's own launch is
  listed straight away. A run that recorded every launch of a launchpad up to
  the head sends the chain readers' `[:autolaunch, :indexer, :lag]` event for it,
  so launches the counter shows and the site has not recorded show as passes
  that stop. A run that recorded a new launch has the count the pages read
  taken again (`Autolaunch.LaunchDiscovery.Count`), so their catching-up
  notice clears.
  """

  @behaviour Autolaunch.ChainRefresh

  require Logger

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, LaunchAbi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.LaunchDiscovery.Count
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias Autolaunch.Stocks.LaunchActions, as: StocksLaunchActions

  @launchpads [:base_revstake, :base_memestock]

  # No job runs while the site is read-only before launch (`Autolaunch.Application`).
  @impl true
  def refresh(chain_id) do
    if not Autolaunch.Prelaunch.read_only?() and
         Enum.any?(launchpads(), &(&1.chain_id == chain_id)),
       do: AshOban.schedule(Autolaunch.LaunchDiscovery, :discover)

    :ok
  end

  def run(_input, _context) do
    case Enum.flat_map(launchpads(), &discover/1) do
      [] -> :ok
      unrecorded -> {:error, {:launches_not_recorded, unrecorded}}
    end
  end

  @doc "The Base launchpads this site discovers launches on."
  def launchpads, do: Enum.filter(Launchpads.configured(), &(&1.launchpad in @launchpads))

  @doc """
  The latest block, the highest launch id `pad` has made at it, how many of
  those launches the site has recorded, and the ids of the ones it has not
  (`missing`), lowest first.
  """
  @spec standing(map()) ::
          {:ok,
           %{
             block: map(),
             made: non_neg_integer(),
             recorded: non_neg_integer(),
             missing: [pos_integer()]
           }}
          | {:error, term()}
  def standing(pad) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, made} <- Launchpads.last_launch_id(pad, block),
         {:ok, recorded} <- recorded(pad) do
      missing = Enum.reject(1..made//1, &MapSet.member?(recorded, &1))
      {:ok, %{block: block, made: made, recorded: made - length(missing), missing: missing}}
    end
  end

  # What `pad` has that could not be recorded this run: launch ids, or the
  # launchpad itself.
  defp discover(pad) do
    case standing(pad) do
      {:ok, %{block: block, missing: missing}} ->
        unrecorded =
          for launch_id <- missing,
              {:error, reason} <- [record(pad, launch_id, block)],
              do: unrecorded(pad, launch_id, reason)

        if length(unrecorded) < length(missing), do: Count.read_again()
        if unrecorded == [], do: followed(pad)
        unrecorded

      {:error, reason} ->
        [unrecorded(pad, :launchpad, reason)]
    end
  end

  defp unrecorded(pad, which, reason) do
    Logger.warning(
      "Launch discovery: #{pad.launchpad} #{name(which)} on chain #{pad.chain_id} not recorded: #{inspect(reason)}"
    )

    {pad.launchpad, pad.chain_id, which}
  end

  defp name(:launchpad), do: "launchpad"
  defp name(launch_id), do: "launch #{launch_id}"

  # Every launch up to the head it read is recorded, so it trails the chain by
  # nothing, as the site's other chain readers say once a pass is done.
  defp followed(pad) do
    :telemetry.execute(
      [:autolaunch, :indexer, :lag],
      %{blocks: 0},
      %{indexer: :launch_discovery, chain_id: pad.chain_id}
    )
  end

  defp recorded(pad) do
    with {:ok, discoveries} <-
           Autolaunch.recorded_launch_discoveries(pad.chain_id, pad.contract, actor: %System{}),
         do: {:ok, MapSet.new(discoveries, & &1.launch_id)}
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
           Launchpads.words(pad, :contract, "launches(uint256)", [launch_id], 5, block),
         {:ok, launcher} <- address(launcher),
         {:ok, auction} <- address(auction),
         {:ok, distribution} <-
           Launchpads.words(
             pad,
             :strategy,
             "distribution(address)",
             [auction],
             LabAbi.distribution_words(),
             block
           ),
         {:ok, [delay]} <-
           Launchpads.words(pad, :strategy, "START_DELAY_BLOCKS()", [], 1, block) do
      start_block = LabAbi.distribution(distribution).start_block
      {:ok, %{launcher: launcher, auction: auction, created_block: start_block - delay}}
    end
  end

  defp created(%{launchpad: :base_memestock} = pad, launch_id, block) do
    with {:ok, [launcher, _token, _stock, auction, _splitter, start_block | _rest]} <-
           Launchpads.words(
             pad,
             :contract,
             "launches(uint256)",
             [launch_id],
             pad.shape.record_words,
             block
           ),
         {:ok, launcher} <- address(launcher),
         {:ok, auction} <- address(auction) do
      lead = StocksLaunchActions.schedule(:base, pad.shape.version).opens
      {:ok, %{launcher: launcher, auction: auction, created_block: start_block - lead}}
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
