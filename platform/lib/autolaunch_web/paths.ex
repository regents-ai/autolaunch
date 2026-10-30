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

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias AutolaunchWeb.ReadFailure
  alias RegentChain.Address

  @doc "The auction's page."
  def auction(auction), do: ~p"/auctions/#{symbol(auction)}/#{auction.path_tail}"

  @doc "One of a wallet's bids: a Base bid's `bid_id`, or `<auction>:<bid>` on Robinhood."
  def bid(id), do: ~p"/portfolio/bids/#{id}"

  @doc "The page of the token the auction launched."
  def token(auction), do: ~p"/tokens/#{symbol(auction)}/#{auction.path_tail}"

  @doc "The token's page with its trade widget open on Stake."
  def token_stake(auction), do: token(auction) <> "?trade=stake#trade"

  @doc "The auction's page, with the site's address."
  def auction_url(auction), do: url(~p"/auctions/#{symbol(auction)}/#{auction.path_tail}")

  @doc "The token's page, with the site's address."
  def token_url(auction), do: url(~p"/tokens/#{symbol(auction)}/#{auction.path_tail}")

  @doc "The auction's record in the public API, with the site's address."
  def auction_record_url(auction), do: url(~p"/api/v1/auctions/#{auction.id}")

  @doc "The token's record in the public API, with the site's address."
  def token_record_url(token), do: url(~p"/api/v1/tokens/#{token.id}")

  @doc """
  The auction's share picture. `version` changes whenever the picture's
  figures do, so sites that keep a picture by its address fetch it again.
  """
  def auction_image_url(auction, version),
    do: url(~p"/auctions/#{symbol(auction)}/#{auction.path_tail}/share.png?#{[v: version]}")

  @doc "The token's share picture; see `auction_image_url/2`."
  def token_image_url(auction, version),
    do: url(~p"/tokens/#{symbol(auction)}/#{auction.path_tail}/share.png?#{[v: version]}")

  @doc "The token's share video for everyone; `version` moves on as its figures do."
  def token_video_url(auction, version),
    do: url(~p"/tokens/#{symbol(auction)}/#{auction.path_tail}/share.mp4?#{[v: version]}")

  @doc "The running auction's share video for everyone; `version` moves on as its figures do."
  def auction_video_url(auction, version),
    do: url(~p"/auctions/#{symbol(auction)}/#{auction.path_tail}/share.mp4?#{[v: version]}")

  @doc "One wallet's share video of the running auction, for that wallet's signed-in owner."
  def auction_wallet_video_url(auction, wallet, version),
    do:
      url(
        ~p"/auctions/#{symbol(auction)}/#{auction.path_tail}/wallets/#{wallet}/share.mp4?#{[v: version]}"
      )

  @doc "One wallet's share video of the token, for that wallet's signed-in owner."
  def wallet_video_url(auction, wallet, version),
    do:
      url(
        ~p"/tokens/#{symbol(auction)}/#{auction.path_tail}/wallets/#{wallet}/share.mp4?#{[v: version]}"
      )

  @doc """
  A covered-call market's (`:covered_calls`, by symbol) or an After-hours
  Exposure series' (`:exposure`, by address) share picture; `version` moves on
  as its figures do.
  """
  def market_image_url(:covered_calls, symbol, version),
    do: url(~p"/covered-calls/#{symbol}/share.png?#{[v: version]}")

  def market_image_url(:exposure, series, version),
    do: url(~p"/after-hour-stocks/#{series}/share.png?#{[v: version]}")

  @doc """
  A covered-call market's or an After-hours Exposure series' share video for
  everyone, or `wallet`'s own for its signed-in owner.
  """
  def market_video_url(:covered_calls, symbol, nil, version),
    do: url(~p"/covered-calls/#{symbol}/share.mp4?#{[v: version]}")

  def market_video_url(:covered_calls, symbol, wallet, version),
    do: url(~p"/covered-calls/#{symbol}/wallets/#{wallet}/share.mp4?#{[v: version]}")

  def market_video_url(:exposure, series, nil, version),
    do: url(~p"/after-hour-stocks/#{series}/share.mp4?#{[v: version]}")

  def market_video_url(:exposure, series, wallet, version),
    do: url(~p"/after-hour-stocks/#{series}/wallets/#{wallet}/share.mp4?#{[v: version]}")

  @doc """
  The one listed auction a page address names, or `:error` when none does or
  the tail is too short to name only one. An address that cannot name an
  auction is `:error` too. A read that fails never passes for a missing page:
  it is logged and raises `AutolaunchWeb.UnavailableError` (503, Try again)
  when the database could not be reached, and `AutolaunchWeb.ReadFailedError`
  (500) for anything else (`AutolaunchWeb.ReadFailure`).
  """
  @spec find_auction(String.t(), String.t()) :: {:ok, struct()} | :error
  def find_auction(symbol, tail) do
    case Autolaunch.list_auctions_by_path(symbol, tail, actor: nil, load: [:fdv]) do
      {:ok, [auction]} -> {:ok, auction}
      {:ok, _none_or_several} -> :error
      {:error, %Ash.Error.Invalid{}} -> :error
      {:error, error} -> ReadFailure.raise!("market page read", error)
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
        |> read!()

      is_binary(auction.token_address) ->
        Autolaunch.get_robinhood_token(auction.token_address, actor: nil, load: [:market_cap])
        |> read!()

      true ->
        :error
    end
  end

  defp read!({:error, error}), do: ReadFailure.raise!("market page read", error)
  defp read!(found), do: found

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
