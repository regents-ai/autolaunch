defmodule Autolaunch.TokenHoldings do
  @moduledoc """
  What an account's verified wallets hold of every graduated token, read from
  the chain each time it is asked.

  Public balances of public tokens: nothing is stored, and only the wallets the
  signed-in account has verified are ever read. Each venue is read at one
  latest block, so every amount on the page is from the same moment.
  """

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.VerifiedSession
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Rpc}
  alias Autolaunch.{Lab, LabRpc, Pool, Token}
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @token_decimals 18
  @shown_places 4

  @type holding :: %{
          token: map(),
          presentation: map(),
          held: String.t()
        }

  @doc "Every token the actor's verified wallets hold, most recently graduated first."
  @spec read(Human.t()) :: {:ok, [holding()]} | {:error, :unavailable}
  def read(%Human{} = actor) do
    with {:ok, wallets} <- wallets(actor),
         {:ok, tokens} <- Autolaunch.list_tokens(actor: actor),
         {:ok, holdings} <- holdings(tokens, wallets) do
      {:ok, Enum.sort_by(holdings, & &1.token.graduated_at, {:desc, DateTime})}
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

  defp holdings(_tokens, []), do: {:ok, []}

  defp holdings(tokens, wallets) do
    tokens
    |> Enum.filter(&base_venue?(&1.auction))
    |> Enum.group_by(& &1.auction.kind)
    |> Enum.reduce_while({:ok, []}, fn {kind, tokens}, {:ok, held} ->
      case venue_holdings(kind, tokens, wallets) do
        {:ok, holdings} -> {:cont, {:ok, holdings ++ held}}
        error -> {:halt, error}
      end
    end)
  end

  # Only the Base venues trade today; the Robinhood chain has no pool reads yet.
  defp base_venue?(%{chain_id: chain_id}), do: chain_id in [8453, Lab.chain_id()]

  defp venue_holdings(kind, tokens, wallets) do
    with {:ok, venue} <- venue(kind),
         do: Enum.reduce_while(tokens, {:ok, []}, &collect(&1, &2, venue, wallets))
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
      if atomic == 0,
        do: {:ok, nil},
        else: {:ok, %{token: token, presentation: Token.presentation(token), held: shown(atomic)}}
    end
  end

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
