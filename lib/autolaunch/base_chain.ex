defmodule Autolaunch.BaseChain do
  @moduledoc false

  @base_mainnet_chain_id 8_453
  @base_sepolia_chain_id 84_532

  @base_mainnet_usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @base_sepolia_usdc "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
  @base_mainnet_regent "0x6f89bca4ea5931edfcb09786267b251dee752b07"

  def base_mainnet_chain_id, do: @base_mainnet_chain_id
  def base_sepolia_chain_id, do: @base_sepolia_chain_id
  def supported_chain_ids, do: [@base_mainnet_chain_id, @base_sepolia_chain_id]

  def chains do
    Enum.map(supported_chain_ids(), &config!/1)
  end

  def supported_chain_id?(chain_id), do: normalize_chain_id(chain_id) in supported_chain_ids()

  def config(@base_sepolia_chain_id) do
    {:ok,
     %{
       id: @base_sepolia_chain_id,
       key: "base-sepolia",
       family: "base",
       label: "Base Sepolia",
       short_label: "Base Sepolia",
       uniswap_network: "base_sepolia",
       testnet?: true,
       canonical_usdc_address: @base_sepolia_usdc,
       canonical_auction_quote_token: nil
     }}
  end

  def config(@base_mainnet_chain_id) do
    {:ok,
     %{
       id: @base_mainnet_chain_id,
       key: "base-mainnet",
       family: "base",
       label: "Base",
       short_label: "Base",
       uniswap_network: "base",
       testnet?: false,
       canonical_usdc_address: @base_mainnet_usdc,
       canonical_auction_quote_token: %{
         address: @base_mainnet_regent,
         symbol: "REGENT",
         decimals: 18,
         role: "auction_quote"
       }
     }}
  end

  def config(_chain_id), do: {:error, :unsupported_base_chain}

  def config!(chain_id) do
    case config(normalize_chain_id(chain_id)) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "unsupported Base chain: #{inspect(reason)}"
    end
  end

  def canonical_usdc_address(@base_mainnet_chain_id), do: {:ok, @base_mainnet_usdc}
  def canonical_usdc_address(@base_sepolia_chain_id), do: {:ok, @base_sepolia_usdc}
  def canonical_usdc_address(_chain_id), do: {:error, :unsupported_base_chain}

  def canonical_regent_address(@base_mainnet_chain_id), do: {:ok, @base_mainnet_regent}
  def canonical_regent_address(_chain_id), do: {:error, :base_mainnet_only}

  def canonical_regent_address!(chain_id) do
    case canonical_regent_address(chain_id) do
      {:ok, address} ->
        address

      {:error, reason} ->
        raise ArgumentError, "unsupported REGENT launch chain: #{inspect(reason)}"
    end
  end

  def canonical_usdc_address!(chain_id) do
    case canonical_usdc_address(chain_id) do
      {:ok, address} -> address
      {:error, reason} -> raise ArgumentError, "unsupported Base chain: #{inspect(reason)}"
    end
  end

  def network_label(chain_id), do: config!(chain_id).label
  def network_key(chain_id), do: config!(chain_id).key

  def normalize_chain_id(value) when is_integer(value), do: value

  def normalize_chain_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def normalize_chain_id(_value), do: nil
end
