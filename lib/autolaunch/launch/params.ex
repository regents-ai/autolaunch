defmodule Autolaunch.Launch.Params do
  @moduledoc false

  @preview_keys ~w(
    agent_id
    token_name
    token_symbol
    minimum_raise_usdc
    recovery_safe_address
    auction_proceeds_recipient
    ethereum_revenue_treasury
    total_supply
    launch_notes
  )a
  @create_job_keys @preview_keys ++
                     ~w(wallet_address message signature nonce issued_at broadcast)a
  @quote_keys ~w(amount max_price estimated_tokens_if_end_now estimated_tokens_if_no_other_bids_change inactive_above_price status_band projected_clearing_price current_clearing_price tx_hash)a
  @position_filter_keys ~w(status)a
  @auction_filter_keys ~w(mode sort)a
  @return_filter_keys ~w(limit offset)a

  def preview_attrs(attrs), do: normalize_keys(attrs, @preview_keys)
  def create_job_attrs(attrs), do: normalize_keys(attrs, @create_job_keys)
  def quote_attrs(attrs), do: normalize_keys(attrs, @quote_keys)
  def bid_registration_attrs(attrs), do: normalize_keys(attrs, [:tx_hash])
  def position_filters(filters), do: normalize_keys(filters, @position_filter_keys)
  def auction_filters(filters), do: normalize_keys(filters, @auction_filter_keys)
  def return_filters(filters), do: normalize_keys(filters, @return_filter_keys)

  defp normalize_keys(value, keys) when is_map(value) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch(value, key) do
        {:ok, fetched} -> Map.put(acc, key, fetched)
        :error -> acc
      end
    end)
  end

  defp normalize_keys(_value, _keys), do: %{}

  defp fetch(map, key) do
    Map.fetch(map, Atom.to_string(key))
  end
end
