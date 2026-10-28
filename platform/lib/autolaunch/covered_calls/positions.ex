defmodule Autolaunch.CoveredCalls.Positions do
  @moduledoc """
  What one wallet has on a covered-call market, read now at the latest block:
  the listings it sold, and on every listing the calls it may still exercise
  and the stock it may claim (`claimable`, which for a seller includes the
  stock due back once the window has closed). The list of listings comes from
  the shared book (`Autolaunch.CoveredCalls.Book`); everything about this
  wallet is read fresh.
  """

  alias Autolaunch.CoveredCalls.{Book, Chain, Deployment}

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def read(symbol, wallet) do
    with {:ok, book} <- Book.read(symbol),
         {:ok, config} <- Deployment.current(),
         {:ok, block, opts} <- Chain.latest(config.lab),
         {:ok, holdings} <- Chain.holdings(book.market, book.listings, wallet, block, opts) do
      {:ok,
       %{
         wallet: wallet,
         now: block.timestamp,
         read_at: DateTime.utc_now(),
         sold: Enum.filter(book.listings, &(&1.seller == wallet)),
         holdings: holdings,
         book: book
       }}
    end
  end
end
