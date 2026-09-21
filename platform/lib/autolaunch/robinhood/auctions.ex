defmodule Autolaunch.Robinhood.Auctions do
  @moduledoc """
  Every Robinhood memestock auction on the local Robinhood lab, newest first,
  for the public auction list: the chain is the only record of these launches.

  Everything is read at one latest block: the launchpad's launch records
  (ids run from 1 to `nextLaunchId() - 1`), each token's own name and symbol,
  the stock the auction is denominated in, and the auction's schedule, stored
  clearing price and currency raised. Nothing here writes, signs or caches.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Amounts, Assets}

  @token_decimals 18

  @type t :: %{
          launch_id: pos_integer(),
          auction: String.t(),
          name: String.t(),
          symbol: String.t(),
          stock_symbol: String.t(),
          state: :created | :active | :graduated | :failed,
          clearing_price: String.t(),
          raised: String.t()
        }

  @doc "The lab's auctions, newest first; none where Robinhood auctions are not open."
  @spec list() :: {:ok, [t()]} | {:error, atom()}
  def list do
    if Lab.configured?(), do: read(), else: {:ok, []}
  end

  defp read do
    with {:ok, config} <- Lab.current(),
         opts = Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, next_id} <- launchpad_uint(config, "nextLaunchId()", [], block, opts) do
      Enum.reduce_while(
        1..(next_id - 1)//1,
        {:ok, []},
        &newest_first(config, &1, &2, block, opts)
      )
    end
  end

  defp newest_first(config, launch_id, {:ok, found}, block, opts) do
    case auction(config, launch_id, block, opts) do
      {:ok, auction} -> {:cont, {:ok, [auction | found]}}
      error -> {:halt, error}
    end
  end

  # `launches(id)`: launcher, newToken, currency, auction, startBlock, endBlock, …
  defp auction(config, launch_id, block, opts) do
    with {:ok, words} <- launch_words(config, launch_id, block, opts),
         {:ok, token} <- Abi.word_address(Enum.at(words, 1)),
         {:ok, stock_address} <- Abi.word_address(Enum.at(words, 2)),
         {:ok, auction} <- Abi.word_address(Enum.at(words, 3)),
         {:ok, stock} <- Assets.fetch(Lab.chain_id(), stock_address),
         {:ok, name} <- Rpc.call_string(token, LabAbi.selector("name()"), block, opts),
         {:ok, symbol} <- Rpc.call_string(token, LabAbi.selector("symbol()"), block, opts),
         {:ok, clearing} <- auction_uint(config, auction, "clearingPrice()", block, opts),
         {:ok, raised} <- auction_uint(config, auction, "currencyRaised()", block, opts),
         {:ok, state} <-
           state(config, auction, Enum.at(words, 4), Enum.at(words, 5), block, opts) do
      {:ok,
       %{
         launch_id: launch_id,
         auction: auction,
         name: name,
         symbol: symbol,
         stock_symbol: stock.symbol,
         state: state,
         clearing_price: Amounts.format_cca_price(clearing, stock.decimals, @token_decimals),
         raised: Rpc.format_units(raised, stock.decimals)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp state(_config, _auction, start_block, _end_block, %{number: number}, _opts)
       when number < start_block,
       do: {:ok, :created}

  defp state(_config, _auction, _start_block, end_block, %{number: number}, _opts)
       when number < end_block,
       do: {:ok, :active}

  defp state(config, auction, _start_block, _end_block, block, opts) do
    data = LabAbi.encode(Lab.abi!(config, :auction), "isGraduated()", [])

    with {:ok, graduated?} <- Rpc.call_bool(auction, data, block, opts),
         do: {:ok, if(graduated?, do: :graduated, else: :failed)}
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
