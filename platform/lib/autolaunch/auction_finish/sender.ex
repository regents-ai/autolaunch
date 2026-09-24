defmodule Autolaunch.AuctionFinish.Sender do
  @moduledoc """
  Sends one call from the finishing wallet and returns its hash.

  The call is simulated first, so a launch that someone else has just finished
  costs nothing. The nonce counts the wallet's pending transactions; the fee
  allows the base fee to double before the transaction stops being included.
  """

  alias Autolaunch.AuctionFinish.Wallet
  alias Autolaunch.Chain.Rpc

  def send_call(pad, %{to: to, data: data}) do
    wallet = Wallet.configured!()
    opts = pad.opts

    with {:ok, gas} <-
           quantity("eth_estimateGas", [%{from: wallet.address, to: to, data: data}], opts),
         {:ok, nonce} <- quantity("eth_getTransactionCount", [wallet.address, "pending"], opts),
         {:ok, tip} <- quantity("eth_maxPriorityFeePerGas", [], opts),
         {:ok, base_fee} <- base_fee(opts) do
      {raw, hash} =
        Wallet.sign(wallet, %{
          chain_id: pad.chain_id,
          nonce: nonce,
          max_priority_fee: tip,
          max_fee: 2 * base_fee + tip,
          gas_limit: gas + div(gas, 5),
          to: to,
          data: data
        })

      with {:ok, _hash} <- Rpc.request("eth_sendRawTransaction", [raw], opts), do: {:ok, hash}
    end
  end

  defp base_fee(opts) do
    case Rpc.request("eth_getBlockByNumber", ["latest", false], opts) do
      {:ok, %{"baseFeePerGas" => base_fee}} -> parse(base_fee)
      {:ok, _header} -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quantity(method, params, opts) do
    with {:ok, value} <- Rpc.request(method, params, opts), do: parse(value)
  end

  defp parse("0x" <> hex) when hex != "" do
    case Integer.parse(hex, 16) do
      {value, ""} -> {:ok, value}
      _malformed -> {:error, :invalid_chain_response}
    end
  end

  defp parse(_value), do: {:error, :invalid_chain_response}
end
