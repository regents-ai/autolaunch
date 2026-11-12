defmodule Autolaunch.Chain.Multicall do
  @moduledoc """
  Many contract reads in few requests. Each batch of reads is one `eth_call` of
  Multicall3's `aggregate3` at the block's own hash, so every answer is from
  that one block; the batches are sent a few at a time and come back in the
  order asked.

  Multicall3 is at the same address on Base and on a fork of it. A read the
  contract refuses comes back as `:reverted`; a batch the node does not answer
  fails every read, since a list missing some of its answers would be wrong,
  not short.
  """

  alias Autolaunch.Chain.Rpc

  @address "0xca11bde05977b3631167028862be2a173976ca11"
  # aggregate3((address target, bool allowFailure, bytes callData)[])
  @selector "0x82ad56cb"
  @batch 200
  @concurrency 8
  @timeout 20_000

  @type read :: {contract :: String.t(), calldata :: String.t()}

  def address, do: @address
  def batch, do: @batch

  @doc "Each read's returned bytes at `block`, or `:reverted`, in the order asked."
  @spec read([read()], Rpc.block(), keyword()) ::
          {:ok, [binary() | :reverted]} | {:error, atom()}
  def read(reads, block, opts) do
    reads
    |> Enum.chunk_every(@batch)
    |> Task.async_stream(&aggregate(&1, block, opts),
      max_concurrency: @concurrency,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, answers}}, {:ok, kept} -> {:cont, {:ok, [answers | kept]}}
      {:ok, {:error, _reason} = error}, _kept -> {:halt, error}
      {:exit, _reason}, _kept -> {:halt, {:error, :chain_unavailable}}
    end)
    |> case do
      {:ok, kept} -> {:ok, kept |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp aggregate(reads, block, opts) do
    with {:ok, returned} <- Rpc.call_raw(@address, encode(reads), block, opts) do
      case decode(returned, length(reads)) do
        :error -> {:error, :invalid_chain_response}
        answers -> {:ok, answers}
      end
    end
  end

  # An array of dynamic tuples: its length, each tuple's offset from the first
  # offset word, then the tuples.
  defp encode(reads) do
    tuples = Enum.map(reads, &tuple/1)

    {offsets, _end} =
      Enum.map_reduce(tuples, length(tuples) * 32, &{<<&2::256>>, &2 + byte_size(&1)})

    @selector <>
      Base.encode16(IO.iodata_to_binary([<<32::256, length(tuples)::256>>, offsets, tuples]),
        case: :lower
      )
  end

  defp tuple({"0x" <> contract, "0x" <> calldata}) do
    data = Base.decode16!(calldata, case: :mixed)
    padding = rem(32 - rem(byte_size(data), 32), 32)

    <<String.to_integer(contract, 16)::256, 1::256, 96::256, byte_size(data)::256, data::binary,
      0::size(padding)-unit(8)>>
  end

  # (bool success, bytes returnData)[], laid out as the request's array is.
  defp decode(<<32::256, count::256, body::binary>>, count) when byte_size(body) >= count * 32 do
    answers = for <<offset::256 <- binary_part(body, 0, count * 32)>>, do: answer(body, offset)
    if :error in answers, do: :error, else: answers
  end

  defp decode(_returned, _count), do: :error

  defp answer(body, offset) when offset <= byte_size(body) do
    case binary_part(body, offset, byte_size(body) - offset) do
      <<1::256, 64::256, size::256, data::binary-size(size), _rest::binary>> -> data
      <<0::256, 64::256, _reason::binary>> -> :reverted
      _malformed -> :error
    end
  end

  defp answer(_body, _offset), do: :error
end
