defmodule Autolaunch.Robinhood.Auctions do
  @moduledoc """
  Every Robinhood memestock auction on the local Robinhood lab, newest first,
  for the public auction and token lists: the chain is the only record of
  these launches, and a graduated launch is a listed token.

  Everything is read at one latest block: the launchpad's launch records
  (ids run from 1 to `nextLaunchId() - 1`), each token's own name and symbol,
  the metadata the launch wrote into it (description, website and image), the
  stock the auction is denominated in, the minimum it must raise, and the
  auction's schedule, stored clearing price and currency raised. An auction's
  state is the launch's own lifecycle once it is finished (graduated or
  failed, set only by `migrate`); before that, its schedule against the block
  clock the contracts keep time by (`Autolaunch.Robinhood.BlockClock`) says
  whether it opens soon, is live, or has ended and waits to be finished.
  Whether the raise has met its minimum is the auction's `isGraduated()`, a
  progress fact only. The launcher had to be its creator's
  signed-in wallet, so each listed auction also names the account whose
  signed-in wallet that still is, when exactly one account's is; its creator's
  X accounts show beside the launch. An image the site stores carries its
  colour (`Autolaunch.ImageColor`). Nothing here writes, signs or caches.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.ImageColor
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{BlockClock, Lab}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Amounts, Assets}

  @token_decimals 18

  @type t :: %{
          launch_id: pos_integer(),
          launcher: String.t(),
          auction: String.t(),
          token: String.t(),
          name: String.t(),
          symbol: String.t(),
          description: String.t() | nil,
          website: String.t() | nil,
          image: String.t() | nil,
          image_color: String.t() | nil,
          stock_address: String.t(),
          stock_symbol: String.t(),
          stock_decimals: non_neg_integer(),
          state: :created | :active | :ended | :graduated | :failed,
          minimum_reached: boolean(),
          clearing_price: String.t(),
          clearing_price_q96: non_neg_integer(),
          raised: String.t(),
          required: String.t(),
          start_block: non_neg_integer(),
          end_block: non_neg_integer(),
          clock: non_neg_integer(),
          creator_human_account_id: pos_integer() | nil
        }

  @doc "The lab's auctions, newest first; none where Robinhood auctions are not open."
  @spec list() :: {:ok, [t()]} | {:error, atom()}
  def list do
    if Lab.configured?(),
      do:
        with(
          {:ok, auctions} <- read(),
          {:ok, auctions} <- with_creators(auctions),
          do: {:ok, with_image_colors(auctions)}
        ),
      else: {:ok, []}
  end

  @doc "Public auctions filtered by mode and ordered by launch id, before Base auctions."
  def list(mode, sort) do
    with {:ok, auctions} <- list() do
      filtered = Enum.filter(auctions, &in_mode?(&1, mode))
      {:ok, if(sort == "oldest", do: Enum.reverse(filtered), else: filtered)}
    end
  end

  @doc "The graduated launches, newest first: every Robinhood token the site lists."
  @spec graduated() :: {:ok, [t()]} | {:error, atom()}
  def graduated do
    with {:ok, auctions} <- list(), do: {:ok, Enum.filter(auctions, &(&1.state == :graduated))}
  end

  @doc "One auction by its address, or `{:error, :not_found}`."
  @spec fetch(String.t()) :: {:ok, t()} | {:error, atom()}
  def fetch(address), do: find(&Address.equal?(&1.auction, address))

  @doc "The graduated launch whose token has this address, or `{:error, :not_found}`."
  @spec fetch_by_token(String.t()) :: {:ok, t()} | {:error, atom()}
  def fetch_by_token(address),
    do: find(&(&1.state == :graduated and Address.equal?(&1.token, address)))

  defp find(match) do
    with {:ok, auctions} <- list() do
      case Enum.find(auctions, match) do
        nil -> {:error, :not_found}
        auction -> {:ok, auction}
      end
    end
  end

  defp in_mode?(_auction, "all"), do: true
  defp in_mode?(auction, mode) when mode in ["biddable", "live"], do: auction.state == :active
  defp in_mode?(auction, "ended"), do: auction.state == :ended
  defp in_mode?(auction, "failed_minimum"), do: auction.state == :failed
  defp in_mode?(auction, "graduated"), do: auction.state == :graduated

  defp with_creators([]), do: {:ok, []}

  defp with_creators(auctions) do
    launchers = auctions |> Enum.map(&String.downcase(&1.launcher)) |> Enum.uniq()

    with {:ok, accounts} <-
           Accounts.list_human_accounts_by_signed_in_wallets(launchers, actor: %System{}) do
      owners = Enum.group_by(accounts, &String.downcase(&1.wallet_address), & &1.id)

      {:ok,
       Enum.map(
         auctions,
         &Map.put(&1, :creator_human_account_id, owner(owners, &1.launcher))
       )}
    end
  end

  defp with_image_colors(auctions) do
    colors = auctions |> Enum.map(& &1.image) |> ImageColor.for_urls()
    Enum.map(auctions, &Map.put(&1, :image_color, colors[&1.image]))
  end

  defp owner(owners, launcher) do
    case Map.get(owners, String.downcase(launcher), []) do
      [id] -> id
      _none_or_several -> nil
    end
  end

  defp read do
    with {:ok, config} <- Lab.current(),
         opts = Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         do: at(config, block, opts)
  end

  @doc "Every auction the launchpad records, newest first, read at the given block, creators not yet named."
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
