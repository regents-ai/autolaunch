defmodule Autolaunch.Robinhood.Launchpad do
  @moduledoc """
  The Robinhood chain as the site reads it, all at one pinned block: the head
  and its rollup clock, one launch record with its token's name, symbol and
  metadata (`Autolaunch.Robinhood.Discovery`), every launchpad's auctions for
  a wallet's portfolio (`Autolaunch.Robinhood.Positions`), one auction's
  market, its floor price and token supply, and a graduated launch's pool
  price (`Autolaunch.AuctionMarket`). New launches are discovered on the
  current launchpad; an auction's market is read from the launchpad of its
  own contracts version.
  """

  alias Autolaunch.Auction.MarketState
  alias Autolaunch.AuctionTerms
  alias Autolaunch.Chain.{Abi, Lifecycle, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{BlockClock, Lab}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.Assets

  def head do
    with {:ok, config} <- Lab.current(),
         opts = Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, clock} <- BlockClock.read(block, opts) do
      {:ok, %{config: config, opts: opts, chain_id: config.chain_id, block: block, clock: clock}}
    end
  end

  def next_launch_id(head), do: launchpad_uint(head, current(head), "nextLaunchId()", [])

  def launch(head, launch_id), do: read_launch(head, current(head), launch_id)

  @doc """
  Every auction the launchpads record, newest first: the current launchpad's,
  then the first Memestock launchpad's (ids run from 1 to `nextLaunchId() - 1`
  on each), each launch as `launch/2` reads it with its state against the
  rollup clock and its auction's stored clearing price.
  """
  def auctions(head) do
    Enum.reduce_while(Lab.versions(head.config), {:ok, []}, fn version, {:ok, found} ->
      case launchpad_auctions(head, version) do
        {:ok, auctions} -> {:cont, {:ok, found ++ auctions}}
        error -> {:halt, error}
      end
    end)
  end

  defp launchpad_auctions(head, version) do
    with {:ok, contracts} <- Lab.contracts(head.config, version),
         {:ok, next_id} <- launchpad_uint(head, contracts, "nextLaunchId()", []) do
      Enum.reduce_while(1..(next_id - 1)//1, {:ok, []}, &newest_first(head, contracts, &1, &2))
    end
  end

  defp newest_first(head, contracts, launch_id, {:ok, found}) do
    case auction(head, contracts, launch_id) do
      {:ok, auction} -> {:cont, {:ok, [auction | found]}}
      error -> {:halt, error}
    end
  end

  defp auction(head, contracts, launch_id) do
    with {:ok, launch} <- read_launch(head, contracts, launch_id),
         {:ok, clearing} <-
           Rpc.call_uint(
             launch.auction,
             auction_call(head, "clearingPrice()"),
             head.block,
             head.opts
           ) do
      {:ok,
       Map.merge(launch, %{
         state:
           MarketState.observed(
             launch.lifecycle,
             head.clock,
             launch.start_block,
             launch.end_block
           ),
         clearing_price_q96: clearing
       })}
    end
  end

  defp read_launch(head, contracts, launch_id) do
    with {:ok, record} <- launch_record(head, contracts, launch_id),
         {:ok, launcher} <- Abi.word_address(record.launcher),
         {:ok, token} <- Abi.word_address(record.new_token),
         {:ok, stock_address} <- Abi.word_address(record.currency),
         {:ok, auction} <- Abi.word_address(record.auction),
         {:ok, stock} <- Assets.fetch(head.chain_id, stock_address),
         {:ok, name} <- token_string(head, token, "name()"),
         {:ok, symbol} <- token_string(head, token, "symbol()"),
         {:ok, metadata} <- metadata(head, token) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         token: token,
         auction: auction,
         launchpad: contracts.launchpad,
         stock: stock,
         name: name,
         symbol: symbol,
         description: metadata["description"],
         website: metadata["website"],
         image: metadata["image"],
         start_block: record.start_block,
         end_block: record.end_block,
         lifecycle: record.lifecycle
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  def terms(head, auction, price), do: AuctionTerms.read(auction, price, head.block, head.opts)

  def market(head, %{auction_address: auction, contracts_version: version}) do
    with {:ok, contracts} <- Lab.contracts(head.config, version),
         {:ok, launch_id} <-
           launchpad_uint(head, contracts, "launchIdOfAuction(address)", [auction]),
         {:ok, record} <- launch_record(head, contracts, launch_id),
         {:ok, minimum_reached} <-
           Rpc.call_bool(auction, auction_call(head, "isGraduated()"), head.block, head.opts),
         {:ok, clearing} <-
           Rpc.call_uint(auction, auction_call(head, "clearingPrice()"), head.block, head.opts),
         {:ok, raised} <-
           Rpc.call_uint(auction, auction_call(head, "currencyRaised()"), head.block, head.opts) do
      {:ok,
       %{
         launch_id: launch_id,
         lifecycle: record.lifecycle,
         start_block: record.start_block,
         end_block: record.end_block,
         minimum_reached: minimum_reached,
         clearing_price_q96: clearing,
         currency_raised: raised,
         pool: pool(contracts, record)
       }}
    end
  end

  # A graduated launch's pool, splitter and liquidity position, all held by
  # the launchpad's locker. `nil` before `migrate` records them.
  defp pool(contracts, record) do
    if Lifecycle.graduated?(record.lifecycle) do
      %{
        pool_id: bytes32(record.pool_id),
        token: address(record.new_token),
        stock: address(record.currency),
        splitter: address(record.splitter),
        lp_token_id: record.lp_token_id,
        locker: contracts.locker
      }
    end
  end

  defp bytes32(word),
    do:
      "0x" <>
        (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))

  defp address(word),
    do:
      "0x" <>
        (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))

  def price_quote(head, pool, stock_decimals) do
    Autolaunch.Pool.pool_price_quote(
      %{
        pool_manager: Lab.address!(head.config, :pool_manager),
        pool_id: pool.pool_id,
        token: pool.token,
        currency: pool.stock,
        currency_decimals: stock_decimals
      },
      head.block,
      head.opts
    )
  end

  # The token's `tokenURI()` is a base64 JSON object holding only the
  # metadata fields the launch filled in.
  defp metadata(head, token) do
    with {:ok, "data:application/json;base64," <> encoded} <-
           token_string(head, token, "tokenURI()"),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, %{} = metadata} <- Jason.decode(json) do
      {:ok, metadata}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp token_string(head, token, signature),
    do: Rpc.call_string(token, LabAbi.selector(signature), head.block, head.opts)

  defp auction_call(head, signature),
    do: LabAbi.encode(Lab.abi!(head.config, :auction), signature, [])

  defp current(head) do
    {:ok, contracts} = Lab.contracts(head.config, :v2)
    contracts
  end

  defp launch_record(head, contracts, launch_id) do
    with {:ok, words} <-
           Rpc.call_words(
             contracts.launchpad,
             LabAbi.encode(contracts.abis["launchpad"], "launches(uint256)", [launch_id]),
             head.block,
             contracts.record_words,
             head.opts
           ),
         do: {:ok, RobinhoodLabAbi.record(contracts, words)}
  end

  defp launchpad_uint(head, contracts, signature, arguments) do
    Rpc.call_uint(
      contracts.launchpad,
      LabAbi.encode(contracts.abis["launchpad"], signature, arguments),
      head.block,
      head.opts
    )
  end
end
