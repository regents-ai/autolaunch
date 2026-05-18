defmodule Autolaunch.Launch.AuctionSync do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.AuctionSnapshotCache
  alias Autolaunch.Launch.Core
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.TokenPricing
  alias Autolaunch.Tokens
  alias Autolaunch.Tokens.RevsplitToken

  @default_batch_size 20

  def sync_once(opts \\ []) do
    candidates = sync_candidates(opts)

    results =
      Enum.map(candidates, fn auction ->
        case sync_auction(auction) do
          {:ok, result} -> result
          {:error, reason} -> %{changed?: false, token?: false, failed?: false, error: reason}
        end
      end)

    {:ok,
     %{
       checked: length(candidates),
       changed: Enum.count(results, & &1.changed?),
       graduated: Enum.count(results, & &1.token?),
       failed: Enum.count(results, & &1.failed?)
     }}
  end

  def sync_auction(%Auction{} = auction) do
    with {:ok, snapshot} <- AuctionSnapshotCache.fetch(auction.chain_id, auction.auction_address),
         {:ok, updated} <- persist_snapshot(auction, snapshot),
         {:ok, token?} <- maybe_upsert_revsplit_token(updated, snapshot) do
      {:ok,
       %{
         changed?: changed?(auction, updated),
         token?: token?,
         failed?: updated.chain_state == "failed_minimum"
       }}
    end
  end

  def sync_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, config_value(:batch_size, @default_batch_size))

    active_chain_id = Keyword.get(opts, :chain_id, active_chain_id())

    Auction
    |> where([auction], auction.chain_id == ^active_chain_id)
    |> where(
      [auction],
      auction.chain_state == "open" or is_nil(auction.onchain_synced_at)
    )
    |> order_by([auction], asc_nulls_first: auction.onchain_synced_at, desc: auction.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp persist_snapshot(%Auction{} = auction, snapshot) do
    observed_at = snapshot_observed_at(snapshot) || DateTime.utc_now()
    chain_state = chain_state(snapshot)
    currency_raised_raw = integer_string(snapshot.currency_raised_wei)
    required_currency_raised_raw = integer_string(snapshot.required_currency_raised_wei)
    clearing_q96 = integer_string(snapshot.checkpoint.clearing_price_q96)
    raised_quote = Tokens.raw_quote_to_string(currency_raised_raw)
    required_quote = Tokens.raw_quote_to_string(required_currency_raised_raw)

    attrs = %{
      chain_state: chain_state,
      onchain_currency_raised_raw: currency_raised_raw,
      onchain_required_currency_raised_raw: required_currency_raised_raw,
      onchain_clearing_price_q96: clearing_q96,
      onchain_start_block: snapshot.start_block,
      onchain_end_block: snapshot.end_block,
      onchain_claim_block: snapshot.claim_block,
      onchain_graduated: snapshot.is_graduated,
      onchain_block_number: snapshot.block_number,
      onchain_synced_at: observed_at,
      metrics_updated_at: observed_at,
      raised_currency:
        if(raised_quote, do: "#{raised_quote} REGENT", else: auction.raised_currency),
      target_currency:
        if(required_quote, do: "#{required_quote} REGENT", else: auction.target_currency),
      progress_percent:
        progress_percent(snapshot.currency_raised_wei, snapshot.required_currency_raised_wei)
    }

    auction
    |> Auction.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_upsert_revsplit_token(%Auction{chain_state: "graduated"} = auction, snapshot) do
    with {:ok, attrs} <- revsplit_token_attrs(auction, snapshot),
         existing? = revsplit_token_exists?(attrs),
         {:ok, _token} <- Tokens.upsert_revsplit_token(attrs) do
      {:ok, not existing?}
    end
  end

  defp maybe_upsert_revsplit_token(%Auction{}, _snapshot), do: {:ok, false}

  defp revsplit_token_attrs(%Auction{} = auction, snapshot) do
    job = job_for_auction(auction)
    price = current_price(auction, job)
    now = DateTime.utc_now()

    attrs = %{
      chain_id: auction.chain_id,
      token_address: auction.token_address,
      source_auction_id: source_auction_id(auction),
      source_job_id: job && job.job_id,
      auction_address: auction.auction_address,
      agent_id: auction.agent_id,
      agent_name: auction.agent_name,
      token_symbol: token_symbol(auction, job),
      subject_id: job && job.subject_id,
      splitter_address: job && job.revenue_share_splitter_address,
      pool_id: job && job.pool_id,
      uniswap_url: auction.uniswap_url,
      auction_quote_token_address: auction.auction_quote_token_address,
      auction_quote_token_symbol: auction.auction_quote_token_symbol,
      auction_quote_token_decimals: auction.auction_quote_token_decimals,
      graduated_at: auction.ends_at,
      graduation_block: snapshot.block_number,
      auction_raise_raw: integer_string(snapshot.currency_raised_wei),
      auction_raise_quote: Tokens.raw_quote_to_string(snapshot.currency_raised_wei),
      required_raise_raw: integer_string(snapshot.required_currency_raised_wei),
      required_raise_quote: Tokens.raw_quote_to_string(snapshot.required_currency_raised_wei),
      clearing_price_quote: Core.q96_price_to_string(snapshot.checkpoint.clearing_price_q96),
      price_quote: price.value,
      price_source: price.source,
      price_updated_at: if(price.value, do: now, else: nil),
      fdv_quote: Tokens.fdv_from_price(price.value),
      revsplit_status: "active",
      last_synced_at: now
    }

    if valid_token_address?(attrs.token_address),
      do: {:ok, attrs},
      else: {:error, :missing_token_address}
  end

  defp current_price(%Auction{} = auction, %Job{} = job)
       when is_binary(job.pool_id) and is_binary(auction.token_address) do
    case price_module().current_token_price_quote(
           auction.chain_id,
           job.pool_id,
           auction.token_address
         ) do
      {:ok, price} -> %{value: price, source: "uniswap_spot"}
      _ -> %{value: nil, source: "uniswap_spot_unavailable"}
    end
  end

  defp current_price(_auction, _job), do: %{value: nil, source: "uniswap_spot_unavailable"}

  defp chain_state(%{is_graduated: true}), do: "graduated"

  defp chain_state(%{block_number: block_number, end_block: end_block})
       when is_integer(block_number) and is_integer(end_block) and block_number >= end_block,
       do: "failed_minimum"

  defp chain_state(_snapshot), do: "open"

  defp progress_percent(currency_raised, required_currency_raised)
       when is_integer(currency_raised) and is_integer(required_currency_raised) and
              required_currency_raised > 0 do
    currency_raised
    |> Decimal.new()
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.div(Decimal.new(required_currency_raised))
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> min(100)
  end

  defp progress_percent(_currency_raised, _required_currency_raised), do: 0

  defp job_for_auction(%Auction{source_job_id: source_job_id}) do
    case source_job_id_to_job_id(source_job_id) do
      nil -> nil
      job_id -> Repo.get(Job, job_id)
    end
  end

  defp source_job_id_to_job_id("auc_" <> rest), do: "job_" <> rest
  defp source_job_id_to_job_id(_source_job_id), do: nil

  defp source_auction_id(%Auction{source_job_id: source_job_id}) when is_binary(source_job_id),
    do: source_job_id

  defp source_auction_id(%Auction{id: id}), do: "auc_#{id}"

  defp token_symbol(_auction, %Job{token_symbol: symbol}) when is_binary(symbol) and symbol != "",
    do: symbol

  defp token_symbol(%Auction{notes: "$" <> symbol}, _job), do: symbol

  defp token_symbol(%Auction{notes: symbol}, _job) when is_binary(symbol) and symbol != "",
    do: symbol

  defp token_symbol(_auction, _job), do: nil

  defp integer_string(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_string(_value), do: nil

  defp snapshot_observed_at(%{observed_at: observed_at}) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, datetime, _offset} -> datetime
      _parse_error -> nil
    end
  end

  defp snapshot_observed_at(_snapshot), do: nil

  defp revsplit_token_exists?(%{chain_id: chain_id, token_address: token_address})
       when is_integer(chain_id) and is_binary(token_address) do
    Repo.exists?(
      from(token in RevsplitToken,
        where: token.chain_id == ^chain_id and token.token_address == ^token_address
      )
    )
  end

  defp revsplit_token_exists?(_attrs), do: false

  defp changed?(%Auction{} = before, %Auction{} = after_sync) do
    keys = [
      :chain_state,
      :onchain_currency_raised_raw,
      :onchain_required_currency_raised_raw,
      :onchain_clearing_price_q96,
      :onchain_start_block,
      :onchain_end_block,
      :onchain_claim_block,
      :onchain_graduated,
      :onchain_block_number
    ]

    Enum.any?(keys, &(Map.get(before, &1) != Map.get(after_sync, &1)))
  end

  defp valid_token_address?("0x" <> hex), do: byte_size(hex) == 40
  defp valid_token_address?(_address), do: false

  defp active_chain_id do
    case InfrastructureConfig.launch_chain_id() do
      {:ok, chain_id} -> chain_id
      _ -> 84_532
    end
  end

  defp config_value(key, default) do
    :autolaunch
    |> Application.get_env(:auction_sync, [])
    |> Keyword.get(key, default)
  end

  defp price_module do
    :autolaunch
    |> Application.get_env(:launch, [])
    |> Keyword.get(:token_pricing_module, TokenPricing)
  end
end
