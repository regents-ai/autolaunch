defmodule Autolaunch.Stocks.Assets do
  @moduledoc """
  The stock currencies of each launch chain, answered from the saved stocks
  (`Autolaunch.Stocks.Stock`), which the site reads from the chain's own stock
  launchpad every five minutes. A stock a launchpad admits is offered here
  with no release; a stock it revokes leaves the list but still answers by
  address, so auctions already trading in it keep working.

  A chain's stocks are read from the database at most once a minute on each
  server and kept in between (`cache/0`); the server whose sync wrote a change
  reads again at once (`changed/0`), the others within the minute. A chain is
  empty when its deployment description is not configured.

  Each stock is its `Autolaunch.Stocks.Stock` row. Base stocks are saved under
  Base's own chain id whichever chain the Base description runs on, since a
  local fork carries the same tokens at the same addresses.

  A saved stock is not proof of admission at the moment of an action: the
  launchpad's own `stockAdmission` is read again before every launch and bid.
  Every address lookup here goes through `RegentChain.Address.equal?/2`:
  lowercase and uppercase match, and mixed case must be a valid checksum.
  """

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.{PriceFeeds, Stock}
  alias RegentChain.Address

  @base_chain_id 8453
  @cache :autolaunch_stock_list

  @doc "The cache each chain's saved stocks are kept in."
  def cache, do: @cache

  @doc "The chain id a draft's stock currency lives on, for each launch chain."
  def chain_id(:base), do: @base_chain_id
  def chain_id(:robinhood), do: RobinhoodLab.chain_id()

  @doc "The chain id a stock launchpad's stocks are saved under."
  def stock_chain_id(%{launchpad: :base_memestock}), do: @base_chain_id
  def stock_chain_id(%{launchpad: :robinhood_memestock, chain_id: chain_id}), do: chain_id

  @doc "The stocks a chain's launchpad admits now, by ticker. A failed read raises."
  @spec all(:base | :robinhood) :: [Stock.t()]
  def all(chain), do: chain |> known() |> Enum.filter(& &1.admitted)

  @doc """
  The stocks a chain's launchpad admits now, by ticker, or the failed read's
  error: for a page that says the list couldn't be read, where `all/1` raises.
  """
  @spec read(:base | :robinhood) :: {:ok, [Stock.t()]} | {:error, term()}
  def read(chain) do
    with {:ok, stocks} <- read_known(chain), do: {:ok, Enum.filter(stocks, & &1.admitted)}
  end

  @doc "The stocks a chain's launchpad admits now or once admitted, by ticker. A failed read raises."
  @spec known(:base | :robinhood) :: [Stock.t()]
  def known(chain) do
    case read_known(chain) do
      {:ok, stocks} -> stocks
      {:error, error} -> raise error
    end
  end

  defp read_known(:base),
    do: if(StocksLab.configured?(), do: saved(@base_chain_id), else: {:ok, []})

  defp read_known(:robinhood),
    do: if(RobinhoodLab.configured?(), do: saved(RobinhoodLab.chain_id()), else: {:ok, []})

  @doc """
  The same company's stock on the other launch chain: the stock that chain's
  launchpad admits under the same ticker.
  """
  @spec counterpart(:base | :robinhood, String.t()) :: {:ok, Stock.t()} | :error
  def counterpart(chain, address) when chain in [:base, :robinhood] and is_binary(address) do
    with %{symbol: symbol} <- Enum.find(all(chain), &Address.equal?(&1.address, address)),
         ticker = PriceFeeds.ticker(symbol),
         %{} = stock <- Enum.find(all(other(chain)), &(PriceFeeds.ticker(&1.symbol) == ticker)) do
      {:ok, stock}
    else
      nil -> :error
    end
  end

  @doc """
  The stock among `stocks` (a chain's admitted stocks, from `read/1`) a link
  names by symbol, in any case, or by address.
  """
  @spec named([Stock.t()], String.t()) :: {:ok, Stock.t()} | :error
  def named(stocks, token) when is_list(stocks) and is_binary(token) do
    wanted = String.trim(token)

    case Enum.find(
           stocks,
           &(String.downcase(&1.symbol) == String.downcase(wanted) or
               Address.equal?(&1.address, wanted))
         ) do
      nil -> :error
      stock -> {:ok, stock}
    end
  end

  @doc "The stock at an address on a chain, admitted now or once admitted."
  @spec fetch(term(), term()) ::
          {:ok, Stock.t()} | {:error, :unsupported_stock | :invalid_address}
  def fetch(@base_chain_id, address) when is_binary(address), do: find(:base, address)

  def fetch(chain_id, address) when is_integer(chain_id) and is_binary(address) do
    if chain_id == RobinhoodLab.chain_id(),
      do: find(:robinhood, address),
      else: {:error, :unsupported_stock}
  end

  def fetch(_chain_id, _address), do: {:error, :unsupported_stock}

  @doc "Drops the stocks this server keeps, so its next reader sees what was just written."
  def changed, do: Cachex.clear!(@cache)

  defp other(:base), do: :robinhood
  defp other(:robinhood), do: :base

  defp find(chain, address) do
    case Address.decode(address) do
      {:ok, _bytes} ->
        case Enum.find(known(chain), &Address.equal?(&1.address, address)) do
          nil -> {:error, :unsupported_stock}
          stock -> {:ok, stock}
        end

      :error ->
        {:error, :invalid_address}
    end
  end

  # Read in whichever process asks, so a page never waits on another's read
  # and a failed read is the asker's own. Kept for no time, nothing is kept;
  # a failed read is never kept.
  defp saved(chain_id) do
    case Application.fetch_env!(:autolaunch, :stock_list_kept_ms) do
      0 -> Autolaunch.launch_currency_stocks(chain_id)
      kept_ms -> kept(chain_id, kept_ms)
    end
  end

  defp kept(chain_id, kept_ms) do
    case Cachex.get!(@cache, chain_id) do
      nil ->
        with {:ok, stocks} <- Autolaunch.launch_currency_stocks(chain_id) do
          Cachex.put!(@cache, chain_id, stocks, expire: kept_ms)
          {:ok, stocks}
        end

      stocks ->
        {:ok, stocks}
    end
  end
end
