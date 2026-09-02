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

  alias Autolaunch.Chain.{Abi, Address}

  @splitter_abi_path Path.expand("../../../contracts/abi/subject-splitter-v1.json", __DIR__)
  @receiver_abi_path Path.expand("../../../contracts/abi/payment-receiver-v1.json", __DIR__)
  @external_resource @splitter_abi_path
  @external_resource @receiver_abi_path

  @uint256_max Integer.pow(2, 256) - 1
  @note_bytes 32

  # The exact fixed decimals of the three bound assets. They are product
  # bindings, never a generic `decimals()` read against an arbitrary token.
  @decimals %{subject: 18, regent: 18, usdc: 6}

  @splitter_actions %{
    stake: {"stake(uint256)", "0xa694fc3a"},
    unstake: {"unstake(uint256)", "0x2e17de78"},
    claim: {"claim(address)", "0x1e83409a"},
    claim_all: {"claimAll()", "0xd1058e59"}
  }

  @receiver_actions %{
    pay: {"pay(address,uint256,bytes32)", "0x5e5571ac"},
    sweep: {"sweep(address,bytes32)", "0x8a738683"},
    set_receiver_note: {"setReceiverNote(bytes32)", "0xb1379b2f"}
  }

  @splitter_reads %{
    subject: {"subject()", "0x0a59a98c"},
    usdc: {"usdc()", "0x3e413bee"},
    regent: {"regent()", "0x35cd696e"},
    treasury: {"treasury()", "0x61d027b3"},
    total_staked: {"totalStaked()", "0x817b1cd2"},
    staked_of: {"stakedOf(address)", "0xaf500ba3"},
    claimable: {"claimable(address,address)", "0xd4570c1c"}
  }

  @receiver_reads %{
    splitter: {"splitter()", "0x3cd8045e"},
    beneficiary: {"beneficiary()", "0x38af3eed"},
    referral_bps: {"referralBps()", "0x1fbb6ff0"},
    note_editor: {"noteEditor()", "0xb73598e7"},
    receiver_note: {"receiverNote()", "0xe5738587"},
    subject: {"subject()", "0x0a59a98c"},
    usdc: {"usdc()", "0x3e413bee"},
    regent: {"regent()", "0x35cd696e"},
    treasury: {"treasury()", "0x61d027b3"}
  }

  @splitter_events %{
    staked:
      {"Staked(address,uint256)",
       "0x9e71bc8eea02a63969f509818f2dafb9254532904319f9dbda79b67bd34a5f3d"},
    unstaked:
      {"Unstaked(address,uint256)",
       "0x0f5bb82176feb1b5e747e28471aa92156a04d9f3ab9f45f28e2d704232b93f75"},
    claimed:
      {"Claimed(address,address,uint256)",
       "0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683"}
  }

  @receiver_events %{
    payment_routed:
      {"PaymentRouted(bytes32,bytes32,address,uint256,uint256,uint256)",
       "0x5f0ce8735b079c7c808fbe22a1dfe2481245f57da458da9cba18c7fd52f612e8"},
    receiver_note_updated:
      {"ReceiverNoteUpdated(bytes32,bytes32)",
       "0x798fd5863d0314c66ec272435fb65ccddd4ac83274382b1c6963a65cb5e4ab9e"}
  }

  # A selector or topic is only evidence if the derived ABI really declares the
  # signature it came from. The check runs inline, against the decoded file
  # alone, so proving it adds no compile-time dependency of its own.
  for {path, functions, events} <- [
        {@splitter_abi_path, Map.merge(@splitter_actions, @splitter_reads), @splitter_events},
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

  # Splitter calls

  @spec encode_stake(non_neg_integer()) :: String.t()
  def encode_stake(amount), do: selector(:stake) <> uint256!(amount)

  @spec encode_unstake(non_neg_integer()) :: String.t()
  def encode_unstake(amount), do: selector(:unstake) <> uint256!(amount)

  @spec encode_claim(String.t()) :: String.t()
  def encode_claim(token), do: selector(:claim) <> address!(token)

  @spec encode_claim_all() :: String.t()
  def encode_claim_all, do: selector(:claim_all)

  # Receiver calls

  @spec encode_pay(String.t(), non_neg_integer(), String.t()) :: String.t()
  def encode_pay(token, amount, payment_reference),
    do: selector(:pay) <> address!(token) <> uint256!(amount) <> bytes32!(payment_reference)

  @spec encode_sweep(String.t(), String.t()) :: String.t()
  def encode_sweep(token, payment_reference),
    do: selector(:sweep) <> address!(token) <> bytes32!(payment_reference)

  @spec encode_set_receiver_note(String.t()) :: String.t()
  def encode_set_receiver_note(note), do: selector(:set_receiver_note) <> bytes32!(note)

  # Reads

  @spec encode_read(atom()) :: String.t()
  def encode_read(id), do: selector(id)

  @spec encode_staked_of(String.t()) :: String.t()
  def encode_staked_of(account), do: selector(:staked_of) <> address!(account)

  @spec encode_claimable(String.t(), String.t()) :: String.t()
  def encode_claimable(token, account),
    do: selector(:claimable) <> address!(token) <> address!(account)

  # Events

  @doc "Exactly one `Staked(account, amount)` from this splitter for this account and amount."
  @spec staked?([map()], String.t(), String.t(), non_neg_integer()) :: boolean()
  def staked?(logs, splitter, account, amount),
    do: account_amount?(logs, :staked, splitter, account, amount)

  @doc "Exactly one `Unstaked(account, amount)` from this splitter for this account and amount."
  @spec unstaked?([map()], String.t(), String.t(), non_neg_integer()) :: boolean()
  def unstaked?(logs, splitter, account, amount),
    do: account_amount?(logs, :unstaked, splitter, account, amount)

  @doc """
  Every positive `Claimed` this splitter emitted for this account, by token.

  A canonical success with no such log is a truthful no-op, so an empty map is a
  legitimate answer. `:error` is reserved for logs that contradict the review:
  another account, a token outside the bound three, a duplicate token, or a
  non-positive amount.
  """
  @spec claimed([map()], String.t(), String.t(), [String.t()]) ::
          {:ok, %{optional(String.t()) => pos_integer()}} | :error
  def claimed(logs, splitter, account, bound_tokens) when is_list(logs) do
    logs
    |> Enum.filter(&emitted_by?(&1, selector(:claimed), splitter))
    |> Enum.reduce_while({:ok, %{}}, fn log, {:ok, claims} ->
      with {:ok, {[account_word, token_word], [amount]}} <- one([log], :claimed, splitter, 2, 1),
           {:ok, ^account} <- Abi.word_address(account_word),
           {:ok, token} <- Abi.word_address(token_word),
           true <- amount > 0,
           true <- Enum.any?(bound_tokens, &Address.equal?(&1, token)),
           false <- Map.has_key?(claims, token) do
        {:cont, {:ok, Map.put(claims, token, amount)}}
      else
        _contradiction -> {:halt, :error}
      end
    end)
  end

  def claimed(_logs, _splitter, _account, _bound_tokens), do: :error

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

  @doc "The one `ReceiverNoteUpdated` this receiver emitted, carrying exactly the reviewed note."
  @spec receiver_note_updated?([map()], String.t(), String.t()) :: boolean()
  def receiver_note_updated?(logs, receiver, note) do
    case one(logs, :receiver_note_updated, receiver, 0, 2) do
      {:ok, {[], [_previous, new_note]}} -> word_hex(new_note) == String.downcase(note)
      _contradiction -> false
    end
  end

  # Notes

  @doc """
  The bytes32 a note's text names: left-aligned UTF-8, zero-padded on the right.

  Empty text is the all-zero word, which clears the note.
  """
  @spec encode_note(String.t()) :: {:ok, String.t()} | :error
  def encode_note(text) when is_binary(text) do
    if String.valid?(text) and byte_size(text) <= @note_bytes do
      {:ok, "0x" <> (text |> Base.encode16(case: :lower) |> String.pad_trailing(64, "0"))}
    else
      :error
    end
  end

  def encode_note(_text), do: :error

  @doc """
  What a stored note says, in the order the product reads it.

  An all-zero word is a cleared note and is answered first, because it also
  carries twelve leading zero bytes and would otherwise read as the zero address.
  Any other word with twelve leading zero bytes is the receiver-address default
  the contract wrote at initialization. Everything else is the editor's own text.
  """
  @spec note_display(String.t()) ::
          :cleared | {:address, String.t()} | {:text, String.t()} | {:opaque, String.t()}
  def note_display("0x" <> hex) when byte_size(hex) == 64 do
    hex = String.downcase(hex)

    case Base.decode16(hex, case: :lower) do
      {:ok, <<0::256>>} -> :cleared
      {:ok, <<0::96, address::binary-size(20)>>} -> {:address, address_hex(address)}
      {:ok, bytes} -> text_note(bytes, hex)
      :error -> {:opaque, "0x" <> hex}
    end
  end

  def note_display(note) when is_binary(note), do: {:opaque, note}

  defp text_note(bytes, hex) do
    trimmed = String.trim_trailing(bytes, <<0>>)

    if String.valid?(trimmed) and String.printable?(trimmed),
      do: {:text, trimmed},
      else: {:opaque, "0x" <> hex}
  end

  defp address_hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

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

  defp account_amount?(logs, id, emitter, account, amount) do
    with {:ok, {[account_word], [^amount]}} <- one(logs, id, emitter, 1, 1),
         {:ok, ^account} <- Abi.word_address(account_word) do
      true
    else
      _contradiction -> false
    end
  end

  defp one(logs, id, emitter, indexed_count, data_words),
    do: Abi.one_event(logs, selector(id), emitter, indexed_count, data_words)

  defp emitted_by?(%{"address" => address, "topics" => [topic | _indexed]}, expected, emitter)
       when is_binary(topic),
       do: String.downcase(topic) == expected and Address.equal?(address, emitter)

  defp emitted_by?(_log, _expected, _emitter), do: false

  defp word_hex(value) when is_integer(value),
    do:
      "0x" <> (value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))

  @entries Map.merge(
             Map.merge(@splitter_actions, @receiver_actions),
             Map.merge(
               Map.merge(@splitter_events, @receiver_events),
               Map.merge(@splitter_reads, @receiver_reads)
             )
           )

  defp entry(id), do: Map.fetch!(@entries, id)
end
