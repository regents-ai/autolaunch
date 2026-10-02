defmodule Autolaunch.Robinhood.Auctions do
  @moduledoc """
  Every Robinhood memestock auction, newest first, read from its chain at one
  pinned block for the portfolio (`Autolaunch.Robinhood.Positions`). The
  public lists and the Robinhood auction and token pages read the stored rows
  the Robinhood market feed keeps (`Autolaunch.Robinhood.MarketFeed`).

  At that block it reads every launchpad's launch records, the current one's
  first and then the first Memestake launchpad's (ids run from 1 to
  `nextLaunchId() - 1` on each), each token's own name and symbol, the metadata the
  launch wrote into it (description, website and image), the stock the
  auction is denominated in, the minimum it must raise, and the auction's
  schedule, stored clearing price and currency raised. An auction's state is
  the launch's own lifecycle once it is finished (graduated or failed, set
  only by `migrate`); before that, its schedule against the block clock the
  contracts keep time by (`Autolaunch.Robinhood.BlockClock`) says whether it
  opens soon, is live, or has ended and waits to be finished. Whether the
  raise has met its minimum is the auction's `isGraduated()`, a progress fact
  only. Nothing here writes, signs or caches.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{BlockClock, Lab}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchActions}

  @token_decimals 18

  @doc "Every auction the launchpads record, newest first, read at the given block."
  @spec at(map(), map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def at(config, block, opts) do
    with {:ok, clock} <- BlockClock.read(block, opts) do
      Enum.reduce_while(
        Lab.versions(config),
        {:ok, []},
        &each_launchpad(config, &1, &2, block, clock, opts)
      )
    end
  end

  defp each_launchpad(config, version, {:ok, found}, block, clock, opts) do
    case launchpad_auctions(config, version, block, clock, opts) do
      {:ok, auctions} -> {:cont, {:ok, found ++ auctions}}
      error -> {:halt, error}
    end
  end

  defp launchpad_auctions(config, version, block, clock, opts) do
    with {:ok, contracts} <- Lab.contracts(config, version),
         {:ok, next_id} <- launchpad_uint(contracts, "nextLaunchId()", [], block, opts) do
      Enum.reduce_while(
        1..(next_id - 1)//1,
        {:ok, []},
        &newest_first(config, contracts, &1, &2, block, clock, opts)
      )
    end
  end

  defp newest_first(config, contracts, launch_id, {:ok, found}, block, clock, opts) do
    case auction(config, contracts, launch_id, block, clock, opts) do
      {:ok, auction} -> {:cont, {:ok, [auction | found]}}
      error -> {:halt, error}
    end
  end

  # A launch's lifecycle is 1 active, 2 graduated, 3 failed.
  defp auction(config, contracts, launch_id, block, clock, opts) do
    with {:ok, words} <- launch_words(contracts, launch_id, block, opts),
         record = RobinhoodLabAbi.record(contracts, words),
         {:ok, launcher} <- Abi.word_address(record.launcher),
         {:ok, token} <- Abi.word_address(record.new_token),
         {:ok, stock_address} <- Abi.word_address(record.currency),
         {:ok, auction} <- Abi.word_address(record.auction),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), stock_address),
         {:ok, name} <- Rpc.call_string(token, LabAbi.selector("name()"), block, opts),
         {:ok, symbol} <- Rpc.call_string(token, LabAbi.selector("symbol()"), block, opts),
         {:ok, metadata} <- metadata(token, block, opts),
         {:ok, clearing} <- auction_uint(config, auction, "clearingPrice()", block, opts),
         {:ok, raised} <- auction_uint(config, auction, "currencyRaised()", block, opts),
         {:ok, minimum_reached} <- minimum_reached(config, auction, block, opts) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         auction: auction,
         token: token,
         name: name,
         symbol: symbol,
         description: metadata["description"],
         website: metadata["website"],
         image: metadata["image"],
         stock_address: stock.address,
         stock_symbol: stock.symbol,
         stock_decimals: stock.decimals,
         state: state(record.lifecycle, record.start_block, record.end_block, clock),
         minimum_reached: minimum_reached,
         clearing_price: Amounts.format_cca_price(clearing, stock.decimals, @token_decimals),
         clearing_price_q96: clearing,
         raised: Rpc.format_units(raised, stock.decimals),
         required: Rpc.format_units(required_raise(contracts.version, record), stock.decimals),
         start_block: record.start_block,
         end_block: record.end_block,
         clock: clock
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # The first launchpad records each launch's required raise; the second has
  # one fixed for every launch.
  defp required_raise(:v1, record), do: record.required_stock_raised
  defp required_raise(:v2, _record), do: LaunchActions.required_stock_raised()

  defp state(2, _start_block, _end_block, _clock), do: :graduated
  defp state(3, _start_block, _end_block, _clock), do: :failed
  defp state(_lifecycle, start_block, _end_block, clock) when clock < start_block, do: :created
  defp state(_lifecycle, _start_block, end_block, clock) when clock < end_block, do: :active
  defp state(_lifecycle, _start_block, _end_block, _clock), do: :ended

  defp minimum_reached(config, auction, block, opts) do
    data = LabAbi.encode(Lab.abi!(config, :auction), "isGraduated()", [])
    Rpc.call_bool(auction, data, block, opts)
  end

  # The token's `tokenURI()` is a base64 JSON object holding only the metadata
  # fields the launch filled in.
  defp metadata(token, block, opts) do
    with {:ok, "data:application/json;base64," <> encoded} <-
           Rpc.call_string(token, LabAbi.selector("tokenURI()"), block, opts),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, %{} = metadata} <- Jason.decode(json) do
      {:ok, metadata}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp launch_words(contracts, launch_id, block, opts) do
    Rpc.call_words(
      contracts.launchpad,
      LabAbi.encode(contracts.abis["launchpad"], "launches(uint256)", [launch_id]),
      block,
      contracts.record_words,
      opts
    )
  end

  defp launchpad_uint(contracts, signature, arguments, block, opts) do
    Rpc.call_uint(
      contracts.launchpad,
      LabAbi.encode(contracts.abis["launchpad"], signature, arguments),
      block,
      opts
    )
  end

  defp auction_uint(config, auction, signature, block, opts),
    do:
      Rpc.call_uint(
        auction,
        LabAbi.encode(Lab.abi!(config, :auction), signature, []),
        block,
        opts
      )
end
