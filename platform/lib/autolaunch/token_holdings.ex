defmodule Autolaunch.TokenHoldings do
  @moduledoc """
  What an account's verified wallets hold of every graduated token, read from
  the chain each time it is asked.

  Public balances of public tokens: nothing is stored, and only the wallets the
  signed-in account has verified are ever read. Each venue is read at one
  latest block, so every amount on the page is from the same moment. Base
  tokens come from the site's token records and link to their token page;
  Robinhood tokens come from the Robinhood launchpad itself, since the chain is
  the only record of those launches, and link to their auction page.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool, Token}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @token_decimals 18
  @shown_places 4

  @type holding :: %{
          name: String.t(),
          symbol: String.t(),
          held: String.t(),
          href: String.t()
        }

  @doc """
  Every token the actor's verified wallets hold: Base tokens most recently
  graduated first, then Robinhood tokens newest launch first.
  """
  @spec read(Human.t()) :: {:ok, [holding()]} | {:error, :unavailable}
  def read(%Human{} = actor) do
    with {:ok, wallets} <- wallets(actor),
         {:ok, tokens} <- Autolaunch.list_tokens(actor: actor),
         {:ok, base} <- base_holdings(tokens, wallets),
         {:ok, robinhood} <- robinhood_holdings(wallets) do
      {:ok, base ++ robinhood}
    else
      _error -> {:error, :unavailable}
    end
  end

  # The same wallets that own the account's bids: verified by the current
  # session, or none at all.
  defp wallets(actor) do
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

  defp base_holdings(_tokens, []), do: {:ok, []}

  defp base_holdings(tokens, wallets) do
    tokens
    |> Enum.sort_by(& &1.graduated_at, {:desc, DateTime})
    |> Enum.group_by(& &1.auction.kind)
    |> Enum.reduce_while({:ok, []}, fn {kind, tokens}, {:ok, held} ->
      case venue_holdings(kind, tokens, wallets) do
        {:ok, holdings} -> {:cont, {:ok, held ++ holdings}}
        error -> {:halt, error}
      end
    end)
  end

  defp venue_holdings(kind, tokens, wallets) do
    with {:ok, venue} <- venue(kind),
         {:ok, held} <- Enum.reduce_while(tokens, {:ok, []}, &collect(&1, &2, venue, wallets)),
         do: {:ok, Enum.reverse(held)}
  end

  defp collect(token, {:ok, held}, venue, wallets) do
    case holding(token, venue, wallets) do
      {:ok, nil} -> {:cont, {:ok, held}}
      {:ok, holding} -> {:cont, {:ok, [holding | held]}}
      error -> {:halt, error}
    end
  end

  defp venue(:agent) do
    with {:ok, config} <- Lab.current(),
         opts = LabRpc.opts(config, "autolaunch portfolio"),
         {:ok, block} <- Rpc.latest_block(opts),
         do: {:ok, %{config: config, block: block, opts: opts}}
  end

  defp venue(:stocks) do
    with {:ok, config} <- StocksLab.current(),
         opts = StocksLab.rpc_opts(config, "autolaunch portfolio"),
         {:ok, block} <- Rpc.latest_block(opts),
         do: {:ok, %{config: config, block: block, opts: opts}}
  end

  defp holding(token, venue, wallets) do
    with {:ok, address} <-
           Pool.token_address(token.auction, venue.config, venue.block, venue.opts),
         {:ok, atomic} <- held(address, wallets, venue) do
      if atomic == 0 do
        {:ok, nil}
      else
        presentation = Token.presentation(token)

        {:ok,
         %{
           name: presentation.name,
           symbol: presentation.symbol,
           held: shown(atomic),
           href: "/tokens/#{token.id}"
         }}
      end
    end
  end

  # Robinhood

  defp robinhood_holdings([]), do: {:ok, []}

  defp robinhood_holdings(wallets) do
    if RobinhoodLab.configured?() do
      with {:ok, config} <- RobinhoodLab.current(),
           opts = RobinhoodLab.rpc_opts(config),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, launches} <- RobinhoodPool.graduated(config, block, opts),
           venue = %{block: block, opts: opts},
           {:ok, held} <-
             Enum.reduce_while(launches, {:ok, []}, &collect_robinhood(&1, &2, venue, wallets)),
           do: {:ok, Enum.reverse(held)}
    else
      {:ok, []}
    end
  end

  defp collect_robinhood(launch, {:ok, held}, venue, wallets) do
    case robinhood_holding(launch, venue, wallets) do
      {:ok, nil} -> {:cont, {:ok, held}}
      {:ok, holding} -> {:cont, {:ok, [holding | held]}}
      error -> {:halt, error}
    end
  end

  # The token names itself: Robinhood launches have no stored record.
  defp robinhood_holding(launch, venue, wallets) do
    case held(launch.token, wallets, venue) do
      {:ok, 0} ->
        {:ok, nil}

      {:ok, atomic} ->
        with {:ok, name} <- erc20_string(launch.token, "name()", venue),
             {:ok, symbol} <- erc20_string(launch.token, "symbol()", venue),
             do:
               {:ok,
                %{
                  name: name,
                  symbol: symbol,
                  held: shown(atomic),
                  href: "/robinhood/auctions/#{launch.auction}"
                }}

      error ->
        error
    end
  end

  defp erc20_string(token, signature, venue),
    do: Rpc.call_string(token, LabAbi.selector(signature), venue.block, venue.opts)

  # One balance across all of the account's wallets.
  defp held(address, wallets, venue) do
    Enum.reduce_while(wallets, {:ok, 0}, fn wallet, {:ok, sum} ->
      case Rpc.call_uint(
             address,
             Abi.encode_erc20("balance_of", [wallet]),
             venue.block,
             venue.opts
           ) do
        {:ok, balance} -> {:cont, {:ok, sum + balance}}
        error -> {:halt, error}
      end
    end)
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
