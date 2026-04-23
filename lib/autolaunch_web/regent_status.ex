defmodule AutolaunchWeb.RegentStatus do
  @moduledoc false

  alias Autolaunch.Cache
  alias Autolaunch.RegentStaking

  @ttl_seconds 15

  def snapshot(current_human \\ nil) do
    case Cache.fetch(cache_key(current_human), @ttl_seconds, fn -> read_status(current_human) end) do
      {:ok, status} -> normalize_status(status)
      {:error, reason} -> unavailable_status(reason)
    end
  end

  defp read_status(current_human) do
    with {:ok, state} <- regent_staking_module().overview(current_human) do
      {:ok,
       %{
         state: if(state.paused, do: "paused", else: "live"),
         chain_label: state.chain_label,
         total_staked: state.total_staked,
         total_recognized_rewards_usdc: state.total_recognized_rewards_usdc,
         wallet_claimable_usdc: Map.get(state, :wallet_claimable_usdc),
         wallet_claimable_regent: Map.get(state, :wallet_claimable_regent)
       }}
    end
  end

  defp normalize_status(%{state: state} = status) do
    %{
      state: state,
      tone: if(state == "paused", do: "warn", else: "live"),
      headline: headline(status),
      detail: detail(status)
    }
  end

  defp normalize_status(status) when is_map(status) do
    status
    |> Map.new(fn {key, value} -> {to_atom_key(key), value} end)
    |> normalize_status()
  end

  defp unavailable_status(:unconfigured) do
    %{
      state: "not-ready",
      tone: "muted",
      headline: "$REGENT staking",
      detail: "Status will appear when staking is configured."
    }
  end

  defp unavailable_status(_reason) do
    %{
      state: "unavailable",
      tone: "warn",
      headline: "$REGENT staking",
      detail: "Status is temporarily unavailable."
    }
  end

  defp headline(%{state: "paused"}), do: "$REGENT staking paused"

  defp headline(%{total_staked: total_staked})
       when is_binary(total_staked) and total_staked != "" do
    "$REGENT #{compact_decimal(total_staked)} staked"
  end

  defp headline(_status), do: "$REGENT staking live"

  defp detail(%{wallet_claimable_usdc: usdc, wallet_claimable_regent: regent})
       when is_binary(usdc) and usdc != "" and is_binary(regent) and regent != "" do
    "Wallet can claim #{compact_decimal(usdc)} USDC and #{compact_decimal(regent)} REGENT."
  end

  defp detail(%{total_recognized_rewards_usdc: rewards, chain_label: chain_label})
       when is_binary(rewards) and rewards != "" do
    "#{compact_decimal(rewards)} USDC recognized on #{chain_label || "Base"}."
  end

  defp detail(%{chain_label: chain_label}), do: "Live on #{chain_label || "Base"}."

  defp compact_decimal(value) do
    value
    |> Decimal.new()
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
  rescue
    _ -> to_string(value)
  end

  defp cache_key(current_human) do
    wallet =
      current_human
      |> primary_wallet()
      |> case do
        nil -> "guest"
        address -> String.downcase(address)
      end

    "regent-status:#{wallet}"
  end

  defp primary_wallet(%{wallet_address: address}) when is_binary(address) and address != "",
    do: address

  defp primary_wallet(_current_human), do: nil

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp regent_staking_module do
    :autolaunch
    |> Application.get_env(:regent_status, [])
    |> Keyword.get(:regent_staking_module, RegentStaking)
  end
end
