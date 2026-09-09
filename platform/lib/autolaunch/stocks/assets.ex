defmodule Autolaunch.Stocks.Assets do
  @moduledoc """
  Founder-selected Base stock currencies for Stocks creation.

  This catalog is not proof of executable contract admission. Issuer policies,
  native B20 support and settlement routes require separate verification.
  Preserve supplied address spelling; resolve identities by chain and address.
  """

  @chain_id 8453
  @oracle_registry "0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD"
  @assets [
    {"AAPLc", "0xb200000000000000000000C2e324d24d7eEcd1fb"},
    {"AMZNc", "0xb200000000000000000000d9192b6B456483C2E8"},
    {"COINc", "0xb200000000000000000000c85a31389D71F3ecfb"},
    {"CRCLc", "0xB20000000000000000000019f6E7C675b73C2e4D"},
    {"GOOGLc", "0xb2000000000000000000002D0BA3164cc74f58B7"},
    {"INTCc", "0xB2000000000000000000004AFF16039bA04bdFBc"},
    {"METAc", "0xb2000000000000000000008bC8786B856E61707C"},
    {"MSFTc", "0xB200000000000000000000Ab99cFa739E253872B"},
    {"MSTRc", "0xb2000000000000000000004884b426556b92883d"},
    {"NVDAc", "0xb20000000000000000000078ee7ce2fE4908108C"},
    {"SNDKc", "0xb200000000000000000000397293Cb8cda9a10c5"},
    {"SPCXc", "0xb2000000000000000000007b9fcbd005511aCBd5"},
    {"TSLAc", "0xb2000000000000000000001e800a7f5189430cD0"}
  ]

  def all do
    Enum.map(@assets, fn {symbol, address} ->
      %{
        chain_id: @chain_id,
        symbol: symbol,
        address: address,
        catalog_status: :listed,
        launch_admission: :unverified
      }
    end)
  end

  def options, do: @assets
  def oracle_registry, do: %{chain_id: @chain_id, address: @oracle_registry}

  def fetch(@chain_id, address) when is_binary(address) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, address) do
      case Enum.find(all(), &(String.downcase(&1.address) == String.downcase(address))) do
        nil -> {:error, :unsupported_stock}
        asset -> {:ok, asset}
      end
    else
      {:error, :invalid_address}
    end
  end

  def fetch(_, _), do: {:error, :unsupported_stock}
end
