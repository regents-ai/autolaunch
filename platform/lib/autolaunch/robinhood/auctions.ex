defmodule Autolaunch.Robinhood.Auctions do
  @moduledoc """
  Every Robinhood memestock auction, newest first, read from its chain at one
  pinned block for the portfolio (`Autolaunch.Robinhood.Positions`). The
  public lists and the Robinhood auction and token pages read the stored rows
  the Robinhood market feed keeps (`Autolaunch.Robinhood.MarketFeed`).

  At that block it reads the launchpad's launch records (ids run from 1 to
  `nextLaunchId() - 1`), each token's own name and symbol, the metadata the
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
  alias Autolaunch.Stocks.{Amounts, Assets}

  @token_decimals 18

  @doc "Every auction the launchpad records, newest first, read at the given block."
  @spec at(map(), map(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def at(config, block, opts) do
    with {:ok, next_id} <- launchpad_uint(config, "nextLaunchId()", [], block, opts),
         {:ok, clock} <- BlockClock.read(block, opts) do
      Enum.reduce_while(
        1..(next_id - 1)//1,
        {:ok, []},
        &newest_first(config, &1, &2, block, clock, opts)
      )
    end
  end

  defp newest_first(config, launch_id, {:ok, found}, block, clock, opts) do
    case auction(config, launch_id, block, clock, opts) do
      {:ok, auction} -> {:cont, {:ok, [auction | found]}}
      error -> {:halt, error}
    end
  end

  # `launches(id)`: launcher, newToken, currency, auction, startBlock, endBlock,
  # …, at word 8 the stock the auction must raise to graduate, and at word 10
  # the launch lifecycle (1 active, 2 graduated, 3 failed).
  defp auction(config, launch_id, block, clock, opts) do
    with {:ok, words} <- launch_words(config, launch_id, block, opts),
         {:ok, launcher} <- Abi.word_address(Enum.at(words, 0)),
         {:ok, token} <- Abi.word_address(Enum.at(words, 1)),
         {:ok, stock_address} <- Abi.word_address(Enum.at(words, 2)),
         {:ok, auction} <- Abi.word_address(Enum.at(words, 3)),
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
         state: state(Enum.at(words, 10), Enum.at(words, 4), Enum.at(words, 5), clock),
         minimum_reached: minimum_reached,
         clearing_price: Amounts.format_cca_price(clearing, stock.decimals, @token_decimals),
         clearing_price_q96: clearing,
         raised: Rpc.format_units(raised, stock.decimals),
         required: Rpc.format_units(Enum.at(words, 8), stock.decimals),
         start_block: Enum.at(words, 4),
         end_block: Enum.at(words, 5),
         clock: clock
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp launch_words(config, launch_id, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), "launches(uint256)", [launch_id]),
      block,
      RobinhoodLabAbi.launch_record_words(),
      opts
    )
  end

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
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
