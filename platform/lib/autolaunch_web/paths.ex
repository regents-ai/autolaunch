defmodule AutolaunchWeb.Paths do
  @moduledoc """
  Where every auction's and token's page and share picture live, on both
  chains: `/auctions/<TICKER>/<tail>` and `/tokens/<TICKER>/<tail>`, where the
  ticker keeps the case it was launched with and the tail is the end of the
  auction's contract address (`Autolaunch.Auction`'s `path_tail`, five
  characters unless another auction with the same ticker shares them). A token
  carries its auction's tail, so the two pages pair up.

  Every function takes the auction, loaded with `path_tail`; a token's page is
  named by the auction it launched from.
  """
  use AutolaunchWeb, :verified_routes

  alias Autolaunch.Chain.Address

  @doc "The auction's page."
  def auction(auction), do: ~p"/auctions/#{symbol(auction)}/#{auction.path_tail}"

  @doc "The page of the token the auction launched."
  def token(auction), do: ~p"/tokens/#{symbol(auction)}/#{auction.path_tail}"

  @doc "The auction's page, with the site's address."
  def auction_url(auction), do: url(~p"/auctions/#{symbol(auction)}/#{auction.path_tail}")

  @doc "The token's page, with the site's address."
  def token_url(auction), do: url(~p"/tokens/#{symbol(auction)}/#{auction.path_tail}")

  @doc """
  The auction's share picture. `version` changes whenever the picture's
  figures do, so sites that keep a picture by its address fetch it again.
  """
  def auction_image_url(auction, version),
    do: url(~p"/auctions/#{symbol(auction)}/#{auction.path_tail}/share.png?#{[v: version]}")

  @doc """
  The one listed auction a page address names, or `:error` when none does or
  the tail is too short to name only one.
  """
  @spec find_auction(String.t(), String.t()) :: {:ok, struct()} | :error
  def find_auction(symbol, tail) do
    case Autolaunch.list_auctions_by_path(symbol, tail, actor: nil, load: [:fdv]) do
      {:ok, [auction]} -> {:ok, auction}
      _none_or_several -> :error
    end
  end

  @doc """
  The page of the Robinhood auction at a contract address, or nil while the
  site does not list it (a launch the chain reported before its row was
  recorded, or one made elsewhere).
  """
  @spec robinhood_auction_page(String.t()) :: String.t() | nil
  def robinhood_auction_page(address), do: with_robinhood_auction(address, &auction/1)

  @doc "The page of the token a Robinhood auction launched; see `robinhood_auction_page/1`."
  @spec robinhood_token_page(String.t()) :: String.t() | nil
  def robinhood_token_page(auction_address),
    do: with_robinhood_auction(auction_address, &token/1)

  defp with_robinhood_auction(address, path) do
    with {:ok, address} <- Address.normalize(address),
         {:ok, %{} = auction} <- Autolaunch.get_robinhood_auction(address, actor: nil) do
      path.(auction)
    else
      _unlisted -> nil
    end
  end

  defp symbol(%{token_symbol: symbol}) when is_binary(symbol), do: symbol
end
