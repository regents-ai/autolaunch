defmodule Autolaunch.Stocks.StockCandidate.ReadMarket do
  @moduledoc """
  Reads what one candidate stock's feed and market look like now, before the
  row is written and outside any transaction.

  1. GeckoTerminal is searched for pools under the stock's symbol (`COINc` on
     Base, `COIN` on Robinhood), the first page of twenty, and the pools of
     the chain's dollar token against one other token are kept.
  2. The chain's latest block is read, after the search, because a refused
     search can wait minutes; everything asked of the chain is asked at that
     one block.
  3. The feed is asked for its latest round. No positive price, or one more
     than seven days old (the age the stock routes refuse a quote at), and
     the row says `:feed_silent`.
  4. The pools' tokens are asked, deepest pool first, until one is the
     issuer's: on Base an address of the form Coinbase's share tokens have
     and that symbol; on Robinhood a token behind Robinhood's stock token
     beacon with that symbol. None, and the row says `:no_dollar_pool`.
  5. That token's deepest dollar pool is saved with its venue and the USD
     GeckoTerminal counts in it: `:qualifies` over $10,000, else `:thin_pool`.

  The search and the pool figures are GeckoTerminal's, not the chain's, and a
  stock whose pools the first page does not show is missed until it does. A
  chain or GeckoTerminal read that fails or answers in another shape fails
  the action and writes nothing; the next hour reads again.
  """

  use Ash.Resource.Change

  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.Rpc
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.GeckoTerminal

  @minimum_usd 10_000
  @feed_max_age_seconds 7 * 24 * 60 * 60
  # A feed answers a signed number; from here up it is negative.
  @negative Integer.pow(2, 255)

  # Whose stock tokens each chain's launchpad takes.
  @issuers %{8453 => :coinbase, 4663 => :robinhood}

  # Where a beacon proxy keeps its beacon (EIP-1967), and the beacon every
  # Robinhood stock token runs behind.
  @beacon_slot "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"
  @robinhood_beacon "e10b6f6b275de231345c20d14ab812db62151b00"

  @unfound %{token: nil, pool: nil, venue: nil, liquidity_usd: nil}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case reading(changeset.data) do
        {:ok, facts} ->
          Ash.Changeset.force_change_attributes(
            changeset,
            Map.put(facts, :read_at, DateTime.utc_now())
          )

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "stock candidate read failed: #{inspect(reason)}")
      end
    end)
  end

  defp reading(candidate) do
    with {:ok, pad} <- pad(candidate.chain_id),
         {:ok, pools} <- dollar_pools(candidate),
         {:ok, head} <- Rpc.latest_block(pad.opts),
         {:ok, true} <- feed_answers?(candidate.feed, head, pad.opts),
         {:ok, pool} <- issuers_pool(pools, candidate, head, pad.opts) do
      {:ok, found(pool)}
    else
      {:ok, false} -> {:ok, Map.put(@unfound, :status, :feed_silent)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pad(chain_id) do
    case Enum.find(
           Launchpads.configured(),
           &(&1.launchpad in [:base_memestock, :robinhood_memestock] and &1.chain_id == chain_id)
         ) do
      nil -> {:error, :chain_not_configured}
      pad -> {:ok, pad}
    end
  end

  # roundId, answer, startedAt, updatedAt, answeredInRound
  defp feed_answers?(feed, head, opts) do
    with {:ok, [_round, answer, _started_at, updated_at, _answered_in]} <-
           Rpc.call_words(feed, LabAbi.selector("latestRoundData()"), head, 5, opts) do
      {:ok,
       answer > 0 and answer < @negative and
         head.timestamp - updated_at <= @feed_max_age_seconds}
    end
  end

  # The dollar token's pools against one other token among the search's first
  # page, deepest first. A pool GeckoTerminal counts no USD for is left out.
  defp dollar_pools(candidate) do
    {network, dollar} = GeckoTerminal.network(candidate.chain_id)
    query = URI.encode_www_form(symbol(candidate))

    case GeckoTerminal.get("/search/pools?query=#{query}&network=#{network}&page=1") do
      {:ok, %{"data" => pools}} when is_list(pools) ->
        {:ok,
         pools
         |> Enum.flat_map(&dollar_pool(&1, network, dollar))
         |> Enum.sort_by(& &1.liquidity_usd, {:desc, Decimal})}

      {:ok, _body} ->
        {:error, :unexpected_answer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dollar_pool(%{"attributes" => attributes} = pool, network, dollar) do
    with [_one, _other] = pair <- GeckoTerminal.pair(pool),
         [token] <- pair -- ["#{network}_#{dollar}"],
         {:ok, token} <- token_address(token, network),
         %{"address" => address, "reserve_in_usd" => usd} when is_binary(address) <- attributes,
         {:ok, usd} <- usd(usd) do
      [%{token: token, pool: address, venue: venue(pool), liquidity_usd: usd}]
    else
      _not_a_dollar_pool -> []
    end
  end

  defp dollar_pool(_pool, _network, _dollar), do: []

  defp token_address(id, network) do
    case String.split(id, "_", parts: 2) do
      [^network, "0x" <> _hex = address] -> {:ok, address}
      _other -> :error
    end
  end

  defp usd(usd) when is_binary(usd) do
    case Decimal.parse(usd) do
      {decimal, ""} ->
        if Decimal.negative?(decimal), do: :error, else: {:ok, Decimal.round(decimal, 2)}

      _unparsed ->
        :error
    end
  end

  defp usd(_usd), do: :error

  defp venue(pool) do
    case get_in(pool, ["relationships", "dex", "data", "id"]) do
      venue when is_binary(venue) -> venue
      _unnamed -> nil
    end
  end

  # The deepest pool whose token is the issuer's, or none. The pools arrive
  # deepest first, so each token is asked about once, at its deepest pool.
  defp issuers_pool(pools, candidate, head, opts) do
    issuer = Map.fetch!(@issuers, candidate.chain_id)
    symbol = symbol(candidate)

    pools
    |> Enum.uniq_by(& &1.token)
    |> Enum.reduce_while({:ok, nil}, fn pool, {:ok, nil} ->
      case issuers?(issuer, pool.token, symbol, head, opts) do
        {:ok, true} -> {:halt, {:ok, pool}}
        {:ok, false} -> {:cont, {:ok, nil}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Coinbase's share tokens sit at addresses of one form, so no other token
  # is asked anything.
  defp issuers?(:coinbase, token, symbol, head, opts) do
    if token =~ ~r/\A0xb20{20}[0-9a-f]{18}\z/,
      do: named?(token, symbol, head, opts),
      else: {:ok, false}
  end

  # The beacon is read from storage, which answers for any address, before a
  # token that may not be a token at all is called.
  defp issuers?(:robinhood, token, symbol, head, opts) do
    with {:ok, true} <- behind_robinhood_beacon?(token, head, opts),
         do: named?(token, symbol, head, opts)
  end

  defp behind_robinhood_beacon?(token, head, opts) do
    block = %{blockHash: head.hash, requireCanonical: true}

    case Rpc.request("eth_getStorageAt", [token, @beacon_slot, block], opts) do
      {:ok, "0x" <> word} when byte_size(word) == 64 ->
        {:ok, String.downcase(binary_part(word, 24, 40)) == @robinhood_beacon}

      {:ok, _answer} ->
        {:error, :invalid_chain_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp named?(token, symbol, head, opts) do
    with {:ok, name} <- Rpc.call_string(token, LabAbi.selector("symbol()"), head, opts),
         do: {:ok, name == symbol}
  end

  # A stock's symbol on its chain: Coinbase's carry a trailing `c`.
  defp symbol(%{chain_id: chain_id, ticker: ticker}) do
    case Map.fetch!(@issuers, chain_id) do
      :coinbase -> ticker <> "c"
      :robinhood -> ticker
    end
  end

  defp found(nil), do: Map.put(@unfound, :status, :no_dollar_pool)

  defp found(pool) do
    status = if Decimal.gt?(pool.liquidity_usd, @minimum_usd), do: :qualifies, else: :thin_pool
    Map.put(pool, :status, status)
  end
end
