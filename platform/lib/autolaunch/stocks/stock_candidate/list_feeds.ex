defmodule Autolaunch.Stocks.StockCandidate.ListFeeds do
  @moduledoc """
  Keeps one candidate row for every stock Chainlink prices on a launch chain
  that the chain's stock launchpad does not admit.

  For Base and Robinhood, where the loaded descriptions name that chain's
  stock launchpad, Chainlink's public feed list is read (the list its own
  site is drawn from) and its stock feeds are picked out by how each issuer's
  are named: `Coinbase AAPL` on Base; `Robinhood AAPL / USD` or
  `Robinhood DELL-USD` on Robinhood, and there also a feed whose asset is a
  `Robinhood Token` (`GLD / USD`). A feed whose ticker an admitted stock
  carries is left out. Each feed left is saved as a row, and a saved row
  whose ticker is no longer among them is removed.

  A list that cannot be read, or that names no stock feed at all, fails the
  run and changes nothing; the job tries again. One read, fifteen seconds at
  most, for each chain. Nothing here signs or sends a transaction.
  """

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Stocks.PriceFeeds

  @directory "https://reference-data-directory.vercel.app"

  # Each chain's list, and whose stock tokens its launchpad takes.
  @lists %{
    8453 => {"feeds-ethereum-mainnet-base-1.json", :coinbase},
    4663 => {"feeds-robinhood-mainnet.json", :robinhood}
  }
  @actor %Autolaunch.Actors.System{}

  def run do
    results =
      for %{launchpad: launchpad, chain_id: chain_id} <- Launchpads.configured(),
          launchpad in [:base_memestock, :robinhood_memestock],
          is_map_key(@lists, chain_id),
          do: list(chain_id)

    Enum.find(results, :ok, &match?({:error, _reason}, &1))
  end

  defp list(chain_id) do
    {file, issuer} = Map.fetch!(@lists, chain_id)

    with {:ok, feeds} <- stock_feeds(file, issuer),
         {:ok, stocks} <- Autolaunch.chain_stocks(chain_id, actor: @actor),
         {:ok, listed} <- Autolaunch.chain_stock_candidates(chain_id, actor: @actor) do
      admitted = for %{admitted: true, symbol: symbol} <- stocks, do: PriceFeeds.ticker(symbol)
      wanted = Map.drop(feeds, admitted)

      kept =
        for {ticker, feed} <- wanted do
          Autolaunch.list_stock_candidate(%{chain_id: chain_id, ticker: ticker, feed: feed},
            actor: @actor
          )
        end

      removed =
        for candidate <- listed, not is_map_key(wanted, candidate.ticker) do
          Autolaunch.unlist_stock_candidate(candidate, actor: @actor)
        end

      Enum.find(kept ++ removed, :ok, &match?({:error, _reason}, &1))
    end
  end

  # The list's stock feeds, as ticker to feed address.
  defp stock_feeds(file, issuer) do
    case Req.get("#{@directory}/#{file}",
           headers: [accept: "application/json"],
           redirect: false,
           connect_options: [timeout: 5_000],
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: feeds}} when is_list(feeds) ->
        named(feeds, issuer)

      {:ok, %{status: 200}} ->
        {:error, :unexpected_answer}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Both chains' lists carry feeds of stocks already admitted, so a list with
  # no stock feed is a broken answer, not a reason to remove every row.
  defp named(feeds, issuer) do
    found =
      for %{"name" => name, "proxyAddress" => proxy} = feed <- feeds,
          is_binary(name) and is_binary(proxy),
          ticker = ticker(issuer, name, feed["assetName"]),
          address = String.downcase(proxy),
          address =~ ~r/\A0x[0-9a-f]{40}\z/,
          into: %{},
          do: {ticker, address}

    if found == %{}, do: {:error, :no_stock_feed_listed}, else: {:ok, found}
  end

  defp ticker(:coinbase, "Coinbase " <> ticker, _asset), do: plain(ticker)
  defp ticker(:robinhood, "Robinhood " <> pair, _asset), do: priced_in_usd(pair)

  defp ticker(:robinhood, pair, asset) when is_binary(asset) do
    if String.ends_with?(asset, "Robinhood Token"), do: priced_in_usd(pair)
  end

  defp ticker(_issuer, _name, _asset), do: nil

  defp priced_in_usd(pair) do
    case String.split(pair, [" / USD", "-USD"]) do
      [ticker, ""] -> plain(ticker)
      _other -> nil
    end
  end

  defp plain(ticker), do: if(ticker =~ ~r/\A[A-Z0-9.]{1,12}\z/, do: ticker)
end
