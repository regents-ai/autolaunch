defmodule Autolaunch.Stocks.FeeAdminChainClient do
  @moduledoc """
  The fork boundary of Stocks fee administration: one snapshot before a review,
  one read after the hash.

  `snapshot/1` answers at one latest block: the launch id behind an auction, its
  current subject lane configuration (`subjectConfig`) and, for a retargeted
  lane, whether the candidate splitter is an authentic Agent splitter (the same
  rule the launchpad enforces). `verify_with_evidence/3` decodes the one event
  each action emits from the canonical receipt and reads the configuration back
  at that block, so a confirmed operation shows the configuration it produced.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc, Pool}
  alias Autolaunch.Stocks.{Lab, LabLaunchChainClient}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @resource "autolaunch_stocks_fee_admin"
  @binding_keys [:launchpad, :hook, :agent_strategy]

  def binding_keys, do: @binding_keys
  def resource, do: @resource

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{auction: auction, splitter: candidate}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config, "autolaunch stocks fee administration"),
         {:ok, block} <- Rpc.latest_block(opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :launchpad), block, opts),
         {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [auction], block, opts),
         true <- launch_id > 0 || {:error, :launch_not_found},
         {:ok, subject} <- Pool.subject_config(config, launch_id, block, opts),
         {:ok, splitter} <- LabLaunchChainClient.splitter_state(config, candidate, block, opts) do
      {:ok,
       %{
         launchpad: Lab.address!(config, :launchpad),
         launch_id: launch_id,
         config: subject,
         splitter: splitter,
         block: block,
         lab_binding: Lab.binding(config, @binding_keys)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify(map(), :action, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, :action, hash) do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: @resource,
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         [current] <- envelope["arguments"]["steps"],
         {:ok, evidence} <- LabRpc.canonical_outcome_evidence(config, envelope, current, hash),
         {:ok, result} <- settled(evidence.outcome, envelope, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  defp settled(:pending, _envelope, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, envelope, config) do
    arguments = envelope["arguments"]
    launch_id = String.to_integer(arguments["launch_id"])
    signer = envelope["expected_signer"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         :ok <- event_matches(arguments["kind"], logs, config, launch_id, signer, arguments),
         {:ok, read_back} <-
           Pool.subject_config(config, launch_id, block, Lab.rpc_opts(config)),
         :ok <- configuration_matches(arguments["kind"], read_back, signer, arguments) do
      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "version" => Integer.to_string(read_back.version),
           "splitter" => read_back.splitter,
           "subject_bps" => Integer.to_string(read_back.subject_bps),
           "administrator" => read_back.administrator,
           "proposed_administrator" => read_back.proposed_administrator,
           "local_block_hash" => block.hash
         }
       }}
    else
      :error -> {:ok, %{outcome: :unverified}}
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `SubjectConfigured(launchId, version, splitter, subjectBps, administrator)`:
  # the version is exactly the reviewed one plus one and the splitter is the
  # reviewed destination (zero for "off").
  defp event_matches("configure_subject", logs, config, launch_id, signer, arguments) do
    with {:ok, {[^launch_id, version, splitter_word], [_bps, administrator_word]}} <-
           event(config, StocksLabAbi.subject_configured_signature(), logs),
         true <- version == String.to_integer(arguments["expected_version"]) + 1,
         true <- same_optional_address(splitter_word, arguments["splitter"]),
         {:ok, administrator} <- Abi.word_address(administrator_word),
         true <- Address.equal?(administrator, signer) do
      :ok
    else
      _contradiction -> :error
    end
  end

  defp event_matches("propose_administrator", logs, config, launch_id, signer, arguments) do
    with {:ok, {[^launch_id, current_word, proposed_word], []}} <-
           event(config, StocksLabAbi.administrator_transfer_started_signature(), logs),
         {:ok, current} <- Abi.word_address(current_word),
         {:ok, proposed} <- Abi.word_address(proposed_word),
         true <- Address.equal?(current, signer),
         true <- Address.equal?(proposed, arguments["proposed_administrator"]) do
      :ok
    else
      _contradiction -> :error
    end
  end

  defp event_matches("accept_administrator", logs, config, launch_id, signer, _arguments) do
    with {:ok, {[^launch_id, _previous_word, current_word], []}} <-
           event(config, StocksLabAbi.administrator_transferred_signature(), logs),
         {:ok, current} <- Abi.word_address(current_word),
         true <- Address.equal?(current, signer) do
      :ok
    else
      _contradiction -> :error
    end
  end

  defp configuration_matches("configure_subject", read_back, _signer, arguments) do
    if read_back.version == String.to_integer(arguments["expected_version"]) + 1 and
         same_optional_address(read_back.splitter, arguments["splitter"]),
       do: :ok,
       else: :error
  end

  defp configuration_matches("propose_administrator", read_back, _signer, arguments) do
    if is_binary(read_back.proposed_administrator) and
         Address.equal?(read_back.proposed_administrator, arguments["proposed_administrator"]),
       do: :ok,
       else: :error
  end

  defp configuration_matches("accept_administrator", read_back, signer, _arguments) do
    if Address.equal?(read_back.administrator, signer) and
         is_nil(read_back.proposed_administrator),
       do: :ok,
       else: :error
  end

  defp event(config, signature, logs) do
    LabAbi.event_words(
      Lab.abi!(config, :launchpad),
      signature,
      logs,
      Lab.address!(config, :launchpad)
    )
  end

  # The zero word and `nil` both mean "no splitter"; anything else has to be the
  # very address the review named.
  defp same_optional_address(0, nil), do: true
  defp same_optional_address(nil, nil), do: true

  defp same_optional_address(word, expected) when is_integer(word) and is_binary(expected) do
    match?({:ok, address} when is_binary(address), Abi.word_address(word)) and
      Address.equal?(elem(Abi.word_address(word), 1), expected)
  end

  defp same_optional_address(actual, expected) when is_binary(actual) and is_binary(expected),
    do: Address.equal?(actual, expected)

  defp same_optional_address(_actual, _expected), do: false

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end
end
