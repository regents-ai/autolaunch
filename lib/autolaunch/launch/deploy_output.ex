defmodule Autolaunch.Launch.DeployOutput do
  @moduledoc false

  alias Autolaunch.BaseChain
  alias Autolaunch.Launch.Job

  def parse(%Job{} = job, output, marker) when is_binary(output) and is_binary(marker) do
    with {:ok, parsed} <- parse_payload(output, marker),
         {:ok, addresses} <- required_addresses(parsed),
         {:ok, identifiers} <- required_identifiers(parsed),
         {:ok, token_metadata} <- required_token_metadata(parsed) do
      {:ok, launch_result(job, output, parsed, addresses, identifiers, token_metadata)}
    else
      {:error, message} ->
        {:error, message, %{stdout_tail: trim_tail(output), stderr_tail: ""}}
    end
  end

  def trim_tail(output) when is_binary(output) do
    String.slice(output, max(String.length(output) - 20_000, 0), 20_000)
  end

  def trim_tail(_output), do: ""

  def to_uniswap_url(chain_id, token_address) do
    case BaseChain.config(chain_id) do
      {:ok, %{uniswap_network: network}} when is_binary(token_address) ->
        "https://app.uniswap.org/explore/tokens/#{network}/#{token_address}"

      _ ->
        nil
    end
  end

  defp parse_payload(output, marker) do
    case latest_marked_json(output, marker) do
      nil -> {:error, "Deployment output missing deterministic marker #{marker}."}
      parsed -> {:ok, parsed}
    end
  end

  defp latest_marked_json(output, marker) do
    output
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(nil, fn line, latest ->
      case String.split(line, marker, parts: 2) do
        [_prefix, suffix] ->
          case Jason.decode(String.trim(suffix)) do
            {:ok, parsed} -> parsed
            _ -> latest
          end

        _ ->
          latest
      end
    end)
  end

  defp required_addresses(parsed) do
    [
      auction_address: "auctionAddress",
      token_address: "tokenAddress",
      strategy_address: "strategyAddress",
      vesting_wallet_address: "vestingWalletAddress",
      hook_address: "hookAddress",
      launch_fee_registry_address: "launchFeeRegistryAddress",
      launch_fee_vault_address: "feeVaultAddress",
      subject_registry_address: "subjectRegistryAddress",
      revenue_share_splitter_address: "revenueShareSplitterAddress",
      default_ingress_address: "defaultIngressAddress",
      auction_quote_token_address: "auctionQuoteTokenAddress",
      revenue_usdc_token_address: "revenueUsdcTokenAddress"
    ]
    |> Enum.reduce_while({:ok, %{}}, fn {key, output_key}, {:ok, acc} ->
      case required_address(parsed, output_key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp required_identifiers(parsed) do
    [
      subject_id: {"subjectId", 64},
      pool_id: {"poolId", 64}
    ]
    |> Enum.reduce_while({:ok, %{}}, fn {key, {output_key, hex_size}}, {:ok, acc} ->
      case required_hex(parsed, output_key, hex_size) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp required_token_metadata(parsed) do
    with {:ok, auction_symbol} <- required_symbol(parsed, "auctionQuoteSymbol", "REGENT"),
         {:ok, auction_decimals} <- required_decimals(parsed, "auctionQuoteDecimals", 18),
         {:ok, revenue_symbol} <- required_symbol(parsed, "revenueSymbol", "USDC"),
         {:ok, revenue_decimals} <- required_decimals(parsed, "revenueDecimals", 6) do
      {:ok,
       %{
         auction_quote_token_symbol: auction_symbol,
         auction_quote_token_decimals: auction_decimals,
         revenue_usdc_token_symbol: revenue_symbol,
         revenue_usdc_token_decimals: revenue_decimals
       }}
    end
  end

  defp launch_result(job, output, parsed, addresses, identifiers, token_metadata) do
    addresses
    |> Map.merge(identifiers)
    |> Map.merge(token_metadata)
    |> Map.merge(%{
      tx_hash: Map.get(parsed, "txHash"),
      uniswap_url: to_uniswap_url(job.chain_id, Map.fetch!(addresses, :token_address)),
      stdout_tail: trim_tail(output),
      stderr_tail: ""
    })
  end

  defp required_address(parsed, key) do
    case normalize_address(Map.get(parsed, key)) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Deployment output did not include #{key}."}
    end
  end

  defp required_hex(parsed, key, bytes) do
    case Map.get(parsed, key) do
      "0x" <> value = hex when byte_size(value) == bytes -> {:ok, String.downcase(hex)}
      _ -> {:error, "Deployment output did not include #{key}."}
    end
  end

  defp required_symbol(parsed, key, expected) do
    case Map.get(parsed, key) do
      value when is_binary(value) ->
        symbol = value |> String.trim() |> String.upcase()

        if symbol == expected do
          {:ok, symbol}
        else
          {:error, "Deployment output #{key} was #{inspect(value)}, expected #{expected}."}
        end

      _ ->
        {:error, "Deployment output did not include #{key}."}
    end
  end

  defp required_decimals(parsed, key, expected) do
    case Map.get(parsed, key) do
      ^expected -> {:ok, expected}
      nil -> {:error, "Deployment output did not include #{key}."}
      value -> {:error, "Deployment output #{key} was #{inspect(value)}, expected #{expected}."}
    end
  end

  defp normalize_address(value) when is_binary(value) do
    trimmed = String.trim(value)
    address = String.downcase(trimmed)
    if Regex.match?(~r/^0x[0-9a-f]{40}$/, address), do: address, else: nil
  end

  defp normalize_address(_value), do: nil
end
