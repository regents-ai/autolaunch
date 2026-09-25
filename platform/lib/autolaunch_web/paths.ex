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
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab

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

  @doc "The token's share picture; see `auction_image_url/2`."
  def token_image_url(auction, version),
    do: url(~p"/tokens/#{symbol(auction)}/#{auction.path_tail}/share.png?#{[v: version]}")

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
  The auction a token page address names and the token it launched, with the
  token's `market_cap`, or `:error` when the address names no auction or its
  token has not launched. A Base token is found by its auction, a Robinhood
  token by the token address its auction recorded.
  """
  @spec find_token(String.t(), String.t()) :: {:ok, struct(), struct()} | :error
  def find_token(symbol, tail) do
    with {:ok, auction} <- find_auction(symbol, tail),
         {:ok, %Autolaunch.Token{} = token} <- launched_token(auction) do
      {:ok, auction, token}
    else
      _none -> :error
    end
  end

  defp launched_token(auction) do
    cond do
      not RobinhoodLab.chain?(auction.chain_id) ->
        Autolaunch.get_public_token_by_auction(auction.id, actor: nil, load: [:market_cap])

      is_binary(auction.token_address) ->
        Autolaunch.get_robinhood_token(auction.token_address, actor: nil, load: [:market_cap])

      true ->
        :error
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
