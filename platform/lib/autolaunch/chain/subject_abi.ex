defmodule Autolaunch.Chain.SubjectAbi do
  @moduledoc """
  The one encoder and decoder for the clean-V1 subject wallet lane.

  Every signature here is declared by an ABI file derived from the exact
  integrated C1 source, and the module refuses to compile unless that file still
  declares it. Each admitted call takes only address, uint256 and bytes32
  arguments, so the whole encoder is three typed static words and a selector:
  there is no dynamic head, no offset and no length prefix anywhere in this lane.

  The browser receives already-reviewed bytes, so nothing outside this module
  ever builds calldata.
  """

  alias Autolaunch.Chain.Abi

  @splitter_abi_path Path.expand("../../../contracts/abi/subject-splitter-v1.json", __DIR__)
  @receiver_abi_path Path.expand("../../../contracts/abi/payment-receiver-v1.json", __DIR__)
  @external_resource @splitter_abi_path
  @external_resource @receiver_abi_path

  @uint256_max Integer.pow(2, 256) - 1

  # The exact fixed decimals of the three bound assets. They are product
  # bindings, never a generic `decimals()` read against an arbitrary token.
  @decimals %{subject: 18, regent: 18, usdc: 6}

  @receiver_actions %{
    pay: {"pay(address,uint256,bytes32)", "0x5e5571ac"},
    sweep: {"sweep(address)", "0x01681a62"}
  }

  @splitter_reads %{
    subject: {"subject()", "0x0a59a98c"},
    usdc: {"usdc()", "0x3e413bee"},
    regent: {"regent()", "0x35cd696e"},
    treasury: {"treasury()", "0x61d027b3"},
    total_staked: {"totalStaked()", "0x817b1cd2"}
  }

  @receiver_reads %{
    splitter: {"splitter()", "0x3cd8045e"},
    beneficiary: {"beneficiary()", "0x38af3eed"},
    referral_bps: {"referralBps()", "0x1fbb6ff0"},
    note_editor: {"noteEditor()", "0xb73598e7"},
    subject: {"subject()", "0x0a59a98c"},
    usdc: {"usdc()", "0x3e413bee"},
    regent: {"regent()", "0x35cd696e"},
    treasury: {"treasury()", "0x61d027b3"}
  }

  @receiver_events %{
    payment_routed:
      {"PaymentRouted(bytes32,bytes32,address,uint256,uint256,uint256)",
       "0x5f0ce8735b079c7c808fbe22a1dfe2481245f57da458da9cba18c7fd52f612e8"}
  }

  # A selector or topic is only evidence if the derived ABI really declares the
  # signature it came from. The check runs inline, against the decoded file
  # alone, so proving it adds no compile-time dependency of its own.
  for {path, functions, events} <- [
        {@splitter_abi_path, @splitter_reads, %{}},
        {@receiver_abi_path, Map.merge(@receiver_actions, @receiver_reads), @receiver_events}
      ] do
    abi = path |> File.read!() |> Jason.decode!()

    for {kind, entries} <- [{"function", functions}, {"event", events}],
        {_id, {signature, _selector}} <- entries do
      declared? =
        Enum.any?(abi, fn
          %{"type" => ^kind, "name" => name, "inputs" => inputs} ->
            "#{name}(#{Enum.map_join(inputs, ",", & &1["type"])})" == signature

          _entry ->
            false
        end)

      declared? || raise "derived C1 ABI #{Path.basename(path)} is missing #{signature}"
    end
  end

  @doc "The exact decimals of one bound asset. Never read generically from a token."
  @spec decimals(:subject | :regent | :usdc) :: pos_integer()
  def decimals(asset), do: Map.fetch!(@decimals, asset)

  @doc "The exact declared signature of one admitted call, read, or event."
  @spec signature(atom()) :: String.t()
  def signature(id), do: id |> entry() |> elem(0)

  @doc "The exact selector of one admitted call or read, or the `topic0` of one admitted event."
  @spec selector(atom()) :: String.t()
  def selector(id), do: id |> entry() |> elem(1)

  # Receiver calls

  @spec encode_pay(String.t(), non_neg_integer(), String.t()) :: String.t()
  def encode_pay(token, amount, payment_reference),
    do: selector(:pay) <> address!(token) <> uint256!(amount) <> bytes32!(payment_reference)

  @spec encode_sweep(String.t()) :: String.t()
  def encode_sweep(token), do: selector(:sweep) <> address!(token)

  # Events

  @doc """
  The one zero-referral `PaymentRouted` this receiver emitted for this reference.

  `referral` must be zero and `net` must equal `gross`, which is what proves the
  canonical treasury-bound economics the review promised. The event supplies the
  actual gross, so a sweep learns the amount it really moved.
  """
  @spec payment_routed([map()], String.t(), String.t(), String.t()) ::
          {:ok, %{gross: pos_integer(), note: String.t()}} | :error
  def payment_routed(logs, receiver, payment_reference, token) do
    with {:ok, {[reference_word, note_word, token_word], [gross, referral, net]}} <-
           one(logs, :payment_routed, receiver, 3, 3),
         {:ok, ^token} <- Abi.word_address(token_word),
         true <- word_hex(reference_word) == String.downcase(payment_reference),
         true <- referral == 0 and net == gross and gross > 0 do
      {:ok, %{gross: gross, note: word_hex(note_word)}}
    else
      _contradiction -> :error
    end
  end

  # Typed static words

  defp address!(address) do
    address
    |> Abi.normalize_address!()
    |> String.trim_leading("0x")
    |> String.pad_leading(64, "0")
  end

  defp uint256!(value) when is_integer(value) and value in 0..@uint256_max,
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  defp uint256!(_value), do: raise(ArgumentError, "uint256 value is invalid")

  defp bytes32!("0x" <> hex) when byte_size(hex) == 64 do
    if String.match?(hex, ~r/^[0-9a-fA-F]+\z/),
      do: String.downcase(hex),
      else: raise(ArgumentError, "bytes32 value is invalid")
  end

  defp bytes32!(_value), do: raise(ArgumentError, "bytes32 value is invalid")

  # Shared decoding

  defp one(logs, id, emitter, indexed_count, data_words),
    do: Abi.one_event(logs, selector(id), emitter, indexed_count, data_words)

  defp word_hex(value) when is_integer(value),
    do:
      "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))

  @entries @receiver_actions
           |> Map.merge(@receiver_events)
           |> Map.merge(@splitter_reads)
           |> Map.merge(@receiver_reads)

  defp entry(id), do: Map.fetch!(@entries, id)
end
