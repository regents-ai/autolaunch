defmodule Autolaunch.SubjectWalletRpcClient do
  @moduledoc """
  The payment card's Base reads, all at one latest block: the splitter's own
  bindings, treasury, total stake and the wallet's stake and claimable amounts;
  the payment receiver's bindings, economics, note and the three balances
  waiting at it; the wallet's three balances; and the allowance between the
  wallet and the spender a payment needs.

  It reads; it never decides. `Autolaunch.SubjectWalletActions` proves every
  binding against the launch's own record before any review exists.
  """

  @behaviour Autolaunch.SubjectWalletChainClient

  alias Autolaunch.Chain.{Abi, Rpc, SubjectAbi}
  alias Autolaunch.{Lab, LabRpc}

  @assets [:subject, :usdc, :regent]

  @impl true
  def snapshot(request) do
    with {:ok, config} <- Lab.current(),
         opts = LabRpc.opts(config, "autolaunch payment card"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, splitter} <- splitter(request, block, opts),
         {:ok, receiver} <- receiver(request.receiver, splitter, block, opts),
         {:ok, balances} <- balances(request.signer, splitter, block, opts),
         {:ok, allowance} <- allowance(request, block, opts) do
      {:ok, %{splitter: splitter, receiver: receiver, balances: balances, allowance: allowance}}
    end
  end

  defp splitter(%{splitter: address, signer: signer}, block, opts) do
    with {:ok, bound} <- addresses(address, [:subject, :usdc, :regent, :treasury], block, opts),
         {:ok, total_staked} <- uint(address, :total_staked, [], block, opts),
         {:ok, staked_of} <- uint(address, :staked_of, [signer], block, opts),
         {:ok, claimable} <-
           per_asset(bound, &uint(address, :claimable, [signer, &1], block, opts)) do
      {:ok,
       Map.merge(bound, %{total_staked: total_staked, staked_of: staked_of, claimable: claimable})}
    end
  end

  defp receiver(nil, _splitter, _block, _opts), do: {:ok, nil}

  defp receiver(address, splitter, block, opts) do
    with {:ok, bound} <-
           addresses(
             address,
             [:splitter, :subject, :usdc, :regent, :treasury, :beneficiary, :note_editor],
             block,
             opts
           ),
         {:ok, referral_bps} <- uint(address, :referral_bps, [], block, opts),
         {:ok, [note]} <-
           Rpc.call_words(address, SubjectAbi.encode_read(:receiver_note, []), block, 1, opts),
         {:ok, balances} <- per_asset(splitter, &balance_of(&1, address, block, opts)) do
      {:ok,
       Map.merge(bound, %{
         referral_bps: referral_bps,
         note:
           "0x" <>
             (note |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")),
         balances: balances
       })}
    end
  end

  # The wallet's balance of each asset the splitter names.
  defp balances(signer, splitter, block, opts),
    do: per_asset(splitter, &balance_of(&1, signer, block, opts))

  defp allowance(%{token: token, spender: spender, signer: signer}, block, opts)
       when is_binary(token) and is_binary(spender),
       do: Rpc.call_uint(token, Abi.encode_erc20("allowance", [signer, spender]), block, opts)

  defp allowance(_request, _block, _opts), do: {:ok, 0}

  defp balance_of(token, holder, block, opts),
    do: Rpc.call_uint(token, Abi.encode_erc20("balance_of", [holder]), block, opts)

  defp uint(address, read, arguments, block, opts),
    do: Rpc.call_uint(address, SubjectAbi.encode_read(read, arguments), block, opts)

  defp addresses(contract, reads, block, opts) do
    Enum.reduce_while(reads, {:ok, %{}}, fn read, {:ok, found} ->
      case Rpc.call_address(contract, SubjectAbi.encode_read(read, []), block, opts) do
        {:ok, address} -> {:cont, {:ok, Map.put(found, read, String.downcase(address))}}
        error -> {:halt, error}
      end
    end)
  end

  # One read for each of the three assets, keyed by asset, from the addresses
  # the splitter itself names.
  defp per_asset(bound, read) do
    Enum.reduce_while(@assets, {:ok, %{}}, fn asset, {:ok, found} ->
      case read.(Map.fetch!(bound, asset)) do
        {:ok, value} -> {:cont, {:ok, Map.put(found, asset, value)}}
        error -> {:halt, error}
      end
    end)
  end
end
