defmodule Autolaunch.TokenHoldings do
  @moduledoc """
  What the signed-in wallet holds, stakes and can claim of every graduated
  token, read from the chain each time it is asked.

  Public facts about public tokens: nothing is stored, and only the wallet the
  session signed in with is read, never the account's other wallets. Each
  chain is read at one latest block, so every amount from that chain is from
  the same moment. Base tokens come from the site's token records; Robinhood
  tokens come from the Robinhood launchpad itself, since the chain is the only
  full record of those launches, and carry the site's listed token record when
  there is one. A token is listed when the wallet holds it, stakes it, or has something to
  claim from its staking contract.
  """

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool, Token}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.{Amounts, StakeActions}
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @token_decimals 18
  @shown_places 4

  @type claimable :: %{amount: String.t(), symbol: String.t()}
  @type holding :: %{
          name: String.t(),
          symbol: String.t(),
          chain: :base | :robinhood,
          held: String.t(),
          staked: String.t(),
          claimable: [claimable()],
          unit: String.t(),
          address: String.t(),
          token: Token.t() | nil
        }

  @doc """
  Every token the signed-in wallet holds, stakes or can claim from: Base
  tokens most recently graduated first, then Robinhood tokens newest launch
  first. The caller reads the wallet from the verified session.
  """
  @spec read_wallet(Human.t(), String.t()) :: {:ok, [holding()]} | {:error, :unavailable}
  def read_wallet(%Human{} = actor, wallet) when is_binary(wallet) do
    with {:ok, tokens} <- Autolaunch.list_tokens(actor: actor),
         {:ok, base} <- base_holdings(tokens, wallet),
         {:ok, robinhood} <- robinhood_holdings(wallet) do
      {:ok, base ++ robinhood}
    else
      _error -> {:error, :unavailable}
    end
  end

  # Base

  defp base_holdings(tokens, wallet) do
    if Lab.configured?() do
      with {:ok, config} <- Lab.current(),
           opts = LabRpc.opts(config, "autolaunch portfolio"),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, venues} <- venues(tokens, block) do
        tokens
        |> Enum.sort_by(& &1.graduated_at, {:desc, DateTime})
        |> collect(&holding(&1, Map.fetch!(venues, &1.auction.kind), wallet))
      end
    else
      {:ok, []}
    end
  end

  # Both Base launch kinds are read at the one block, each on its own deployment.
  defp venues(tokens, block) do
    tokens
    |> Enum.map(& &1.auction.kind)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn kind, {:ok, venues} ->
      case venue(kind, block) do
        {:ok, venue} -> {:cont, {:ok, Map.put(venues, kind, venue)}}
        error -> {:halt, error}
      end
    end)
  end

  defp venue(:agent, block) do
    with {:ok, config} <- Lab.current(),
         do:
           {:ok,
            %{config: config, block: block, opts: LabRpc.opts(config, "autolaunch portfolio")}}
  end

  defp venue(:stocks, block) do
    with {:ok, config} <- StocksLab.current(),
         do:
           {:ok,
            %{
              config: config,
              block: block,
              opts: StocksLab.rpc_opts(config, "autolaunch portfolio")
            }}
  end

  # A row whose auction contract does not exist at this head (a launch from an
  # earlier lab run) has nothing to read; the market feeds skip it the same way.
  defp holding(token, venue, wallet) do
    case LabRpc.ensure_contract(token.auction.auction_address, venue.block, venue.opts) do
      :ok -> read_holding(token, venue, wallet)
      {:error, :lab_contract_missing} -> {:ok, nil}
      error -> error
    end
  end

  defp read_holding(token, venue, wallet) do
    with {:ok, pool} <- Pool.read_at(token.auction, venue.config, venue.block, venue.opts),
         {:ok, position} <- position(pool, wallet) do
      presentation = Token.presentation(token)
      {:ok, entry(presentation.name, presentation.symbol, pool, position, token)}
    end
  end

  # Robinhood

  defp robinhood_holdings(wallet) do
    if RobinhoodLab.configured?() do
      with {:ok, config} <- RobinhoodLab.current(),
           opts = RobinhoodLab.rpc_opts(config),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, launches} <- RobinhoodPool.graduated(config, block, opts) do
        venue = %{config: config, block: block, opts: opts}
        collect(launches, &robinhood_holding(&1, venue, wallet))
      end
    else
      {:ok, []}
    end
  end

  # The token names itself: a Robinhood launch has a listed record only when
  # it was launched through this site.
  defp robinhood_holding(launch, venue, wallet) do
    with {:ok, pool} <-
           RobinhoodPool.read_at(launch.auction, venue.config, venue.block, venue.opts),
         {:ok, position} <- position(pool, wallet),
         {:ok, name} <-
           Rpc.call_string(launch.token, LabAbi.selector("name()"), venue.block, venue.opts),
         {:ok, token} <- Autolaunch.get_robinhood_token(launch.token, actor: nil) do
      {:ok, entry(name, pool.token.symbol, pool, position, token)}
    end
  end

  # Shared

  # Every entry in order, leaving out tokens the wallet has nothing in.
  defp collect(items, read) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, found} ->
      case read.(item) do
        {:ok, nil} -> {:cont, {:ok, found}}
        {:ok, entry} -> {:cont, {:ok, [entry | found]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  # The wallet's position in base units: what it holds, what it staked and
  # what the staking contract owes it per asset.
  defp position(pool, wallet) do
    with {:ok, position} <- StakeActions.position(pool, wallet) do
      {:ok,
       %{
         held: position.balance.atomic,
         staked: position.staked.atomic,
         dollar: position.claimable.dollar.atomic,
         token: position.claimable.token.atomic,
         currency: position.claimable.stock.atomic
       }}
    end
  end

  defp entry(name, symbol, pool, position, token) do
    claimable =
      [
        {position.dollar, pool.fees.splitter.dollar},
        {position.token, pool.token},
        {position.currency, pool.currency}
      ]
      |> Enum.filter(fn {atomic, _asset} -> atomic > 0 end)
      |> Enum.map(fn {atomic, asset} ->
        %{
          amount: Amounts.compact_decimal(Rpc.format_units(atomic, asset.decimals)),
          symbol: asset.symbol
        }
      end)

    if position.held == 0 and position.staked == 0 and claimable == [] do
      nil
    else
      %{
        name: name,
        symbol: symbol,
        chain: pool.chain,
        held: shown(position.held),
        staked: shown(position.staked),
        claimable: claimable,
        unit: pool.currency.symbol,
        address: pool.token.address,
        token: token
      }
    end
  end

  # The same reading as the swap form's balance line: cut, never rounded up.
  defp shown(atomic) do
    atomic
    |> Decimal.new()
    |> Decimal.div(Decimal.new(Integer.pow(10, @token_decimals)))
    |> Decimal.round(@shown_places, :down)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end
end
