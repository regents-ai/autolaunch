defmodule Autolaunch.TokenHoldings do
  @moduledoc """
  What an account's verified wallets hold, stake and can claim of every
  graduated token, read from the chain each time it is asked.

  Public facts about public tokens: nothing is stored, and only the wallets the
  signed-in account has verified are ever read. Each chain is read at one
  latest block, so every amount from that chain is from the same moment, and
  the reading names that block. Base tokens come from the site's token records
  and link to their token page; Robinhood tokens come from the Robinhood
  launchpad itself, since the chain is the only record of those launches, and
  link to their own token page once the site lists their auction. A token is listed when the wallets hold it,
  stake it, or have something to claim from its staking contract.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool, Token}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.{Amounts, StakeActions}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.Paths

  @token_decimals 18
  @shown_places 4
  @none %{holdings: [], blocks: %{}}

  @type claimable :: %{amount: String.t(), symbol: String.t()}
  @type holding :: %{
          name: String.t(),
          symbol: String.t(),
          chain: :base | :robinhood,
          held: String.t(),
          staked: String.t(),
          claimable: [claimable()],
          href: String.t() | nil
        }
  @type reading :: %{
          holdings: [holding()],
          blocks: %{optional(:base) => pos_integer(), optional(:robinhood) => pos_integer()}
        }

  @doc """
  Every token the actor's verified wallets hold, stake or can claim from: Base
  tokens most recently graduated first, then Robinhood tokens newest launch
  first, with the block each chain was read at.
  """
  @spec read(Human.t()) :: {:ok, reading()} | {:error, :unavailable}
  def read(%Human{} = actor) do
    with {:ok, wallets} <- verified_wallets(actor),
         {:ok, tokens} <- Autolaunch.list_tokens(actor: actor),
         {:ok, base} <- base_holdings(tokens, wallets),
         {:ok, robinhood} <- robinhood_holdings(wallets) do
      {:ok,
       %{
         holdings: base.holdings ++ robinhood.holdings,
         blocks: Map.merge(base.blocks, robinhood.blocks)
       }}
    else
      _error -> {:error, :unavailable}
    end
  end

  @doc """
  The same wallets that own the account's bids: verified by the current
  session, or none at all.
  """
  @spec verified_wallets(Human.t()) :: {:ok, [String.t()]} | {:error, term()}
  def verified_wallets(%Human{} = actor) do
    with {:ok, account} when not is_nil(account) <-
           Accounts.get_human_account(actor.human_account_id, actor: actor),
         true <- VerifiedSession.current?(account) do
      {:ok, account.wallet_addresses |> Enum.flat_map(&normalized/1) |> Enum.uniq()}
    else
      false -> {:ok, []}
      error -> error
    end
  end

  defp normalized(wallet) do
    case Address.normalize(wallet) do
      {:ok, address} -> [address]
      :error -> []
    end
  end

  # Base

  defp base_holdings(_tokens, []), do: {:ok, @none}

  defp base_holdings(tokens, wallets) do
    if Lab.configured?() do
      with {:ok, config} <- Lab.current(),
           opts = LabRpc.opts(config, "autolaunch portfolio"),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, venues} <- venues(tokens, block),
           {:ok, holdings} <-
             tokens
             |> Enum.sort_by(& &1.graduated_at, {:desc, DateTime})
             |> collect(&holding(&1, Map.fetch!(venues, &1.auction.kind), wallets)) do
        {:ok, %{holdings: holdings, blocks: %{base: block.number}}}
      end
    else
      {:ok, @none}
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
  defp holding(token, venue, wallets) do
    case LabRpc.ensure_contract(token.auction.auction_address, venue.block, venue.opts) do
      :ok -> read_holding(token, venue, wallets)
      {:error, :lab_contract_missing} -> {:ok, nil}
      error -> error
    end
  end

  defp read_holding(token, venue, wallets) do
    with {:ok, pool} <- Pool.read_at(token.auction, venue.config, venue.block, venue.opts),
         {:ok, position} <- position(pool, wallets) do
      presentation = Token.presentation(token)

      {:ok,
       entry(presentation.name, presentation.symbol, pool, position, Paths.token(token.auction))}
    end
  end

  # Robinhood

  defp robinhood_holdings([]), do: {:ok, @none}

  defp robinhood_holdings(wallets) do
    if RobinhoodLab.configured?() do
      with {:ok, config} <- RobinhoodLab.current(),
           opts = RobinhoodLab.rpc_opts(config),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, launches} <- RobinhoodPool.graduated(config, block, opts),
           venue = %{config: config, block: block, opts: opts},
           {:ok, holdings} <- collect(launches, &robinhood_holding(&1, venue, wallets)) do
        {:ok, %{holdings: holdings, blocks: %{robinhood: block.number}}}
      end
    else
      {:ok, @none}
    end
  end

  # The token names itself: Robinhood launches have no stored record.
  defp robinhood_holding(launch, venue, wallets) do
    with {:ok, pool} <-
           RobinhoodPool.read_at(launch.auction, venue.config, venue.block, venue.opts),
         {:ok, position} <- position(pool, wallets),
         {:ok, name} <-
           Rpc.call_string(launch.token, LabAbi.selector("name()"), venue.block, venue.opts) do
      page = Paths.robinhood_token_page(launch.auction)
      {:ok, entry(name, pool.token.symbol, pool, position, page)}
    end
  end

  # Shared

  # Every entry in order, leaving out tokens the wallets have nothing in.
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

  # One position across all of the account's wallets, in base units: what they
  # hold, what they staked and what the staking contract owes them per asset.
  defp position(pool, wallets) do
    Enum.reduce_while(
      wallets,
      {:ok, %{held: 0, staked: 0, dollar: 0, token: 0, currency: 0}},
      fn wallet, {:ok, sum} ->
        case StakeActions.position(pool, wallet) do
          {:ok, position} ->
            {:cont,
             {:ok,
              %{
                held: sum.held + position.balance.atomic,
                staked: sum.staked + position.staked.atomic,
                dollar: sum.dollar + position.claimable.dollar.atomic,
                token: sum.token + position.claimable.token.atomic,
                currency: sum.currency + position.claimable.stock.atomic
              }}}

          error ->
            {:halt, error}
        end
      end
    )
  end

  defp entry(name, symbol, pool, position, href) do
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
        href: href
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
