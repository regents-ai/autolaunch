defmodule Autolaunch.Tokens do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Repo
  alias Autolaunch.Tokens.RevsplitToken

  @directory_supply Decimal.new("100000000000")

  def list_revsplit_tokens(filters \\ %{}) do
    sort = Map.get(filters, "sort", "trending")
    search = filters |> Map.get("search", "") |> to_string() |> String.trim()

    RevsplitToken
    |> maybe_filter_search(search)
    |> apply_sort(sort)
    |> Repo.all()
    |> Enum.map(&serialize_revsplit_token/1)
  end

  def get_graduated_token(chain_id, token_address) do
    with chain_id when is_integer(chain_id) <- Autolaunch.BaseChain.normalize_chain_id(chain_id),
         token_address when is_binary(token_address) <-
           Autolaunch.Evm.normalize_address(token_address),
         %RevsplitToken{} = token <-
           Repo.one(
             from token in RevsplitToken,
               where:
                 token.chain_id == ^chain_id and token.token_address == ^token_address and
                   token.revsplit_status == "active",
               limit: 1
           ) do
      {:ok, serialize_revsplit_token(token)}
    else
      _ -> {:error, :token_not_found}
    end
  end

  def upsert_revsplit_token(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    attrs = Map.put_new(attrs, :last_synced_at, now)

    %RevsplitToken{}
    |> RevsplitToken.changeset(attrs)
    |> Repo.insert(
      conflict_target: [:chain_id, :token_address],
      on_conflict:
        {:replace,
         [
           :source_auction_id,
           :source_job_id,
           :auction_address,
           :agent_id,
           :agent_name,
           :token_symbol,
           :subject_id,
           :splitter_address,
           :pool_id,
           :uniswap_url,
           :auction_quote_token_address,
           :auction_quote_token_symbol,
           :auction_quote_token_decimals,
           :graduated_at,
           :graduation_block,
           :auction_raise_raw,
           :auction_raise_quote,
           :required_raise_raw,
           :required_raise_quote,
           :clearing_price_quote,
           :price_quote,
           :price_source,
           :price_updated_at,
           :fdv_quote,
           :revsplit_status,
           :last_synced_at,
           :updated_at
         ]},
      returning: true
    )
  end

  def fdv_from_price(nil), do: nil

  def fdv_from_price(price) when is_binary(price) do
    price
    |> Decimal.new()
    |> Decimal.mult(@directory_supply)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  rescue
    _ -> nil
  end

  def raw_quote_to_string(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new("1000000000000000000"))
    |> Decimal.round(18)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  def raw_quote_to_string(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> raw_quote_to_string(integer)
      _ -> nil
    end
  end

  def raw_quote_to_string(_value), do: nil

  defp maybe_filter_search(query, ""), do: query

  defp maybe_filter_search(query, search) do
    needle = "%#{search}%"

    where(
      query,
      [token],
      ilike(token.agent_name, ^needle) or ilike(token.token_symbol, ^needle) or
        ilike(token.agent_id, ^needle) or ilike(token.token_address, ^needle)
    )
  end

  defp apply_sort(query, "newest"),
    do: order_by(query, [token], desc: token.graduated_at, desc: token.inserted_at)

  defp apply_sort(query, "top_raise"),
    do:
      order_by(query, [token],
        desc: fragment("NULLIF(?, '')::numeric", token.auction_raise_quote),
        desc: token.graduated_at
      )

  defp apply_sort(query, _sort),
    do: order_by(query, [token], desc: token.last_synced_at, desc: token.graduated_at)

  defp serialize_revsplit_token(%RevsplitToken{} = token) do
    %{
      id: "token-#{token.chain_id}-#{token.token_address}",
      chain_id: token.chain_id,
      token_address: token.token_address,
      source_auction_id: token.source_auction_id,
      source_job_id: token.source_job_id,
      auction_address: token.auction_address,
      agent_id: token.agent_id,
      agent_name: token.agent_name,
      token_symbol: token.token_symbol,
      subject_id: token.subject_id,
      splitter_address: token.splitter_address,
      pool_id: token.pool_id,
      uniswap_url: token.uniswap_url,
      auction_quote_token_address: token.auction_quote_token_address,
      auction_quote_token_symbol: token.auction_quote_token_symbol,
      auction_quote_token_decimals: token.auction_quote_token_decimals,
      graduated_at: iso(token.graduated_at),
      graduation_block: token.graduation_block,
      auction_raise_raw: token.auction_raise_raw,
      auction_raise_quote: token.auction_raise_quote,
      required_raise_raw: token.required_raise_raw,
      required_raise_quote: token.required_raise_quote,
      clearing_price_quote: token.clearing_price_quote,
      price_quote: token.price_quote,
      price_source: token.price_source,
      price_updated_at: iso(token.price_updated_at),
      fdv_quote: token.fdv_quote,
      revsplit_status: token.revsplit_status,
      last_synced_at: iso(token.last_synced_at),
      detail_url: subject_url(token) || auction_url(token),
      auction_url: auction_url(token),
      subject_url: subject_url(token)
    }
  end

  defp subject_url(%RevsplitToken{subject_id: subject_id})
       when is_binary(subject_id) and subject_id != "",
       do: "/subjects/#{subject_id}"

  defp subject_url(_token), do: nil

  defp auction_url(%RevsplitToken{source_auction_id: auction_id}) when is_binary(auction_id),
    do: "/auctions/#{auction_id}"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
