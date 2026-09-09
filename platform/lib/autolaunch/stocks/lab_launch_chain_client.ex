defmodule Autolaunch.Stocks.LabLaunchChainClient do
  @moduledoc """
  The one fork boundary a Stocks launch has: one snapshot before review, one
  read after the hash.

  `snapshot/1` answers at one latest block: the launchpad's pause state, the
  admission record of the chosen STOCK, and, when a subject lane is requested,
  whether the candidate splitter is the one the Agent strategy recorded for its
  own subject. `verify/3` decodes the launchpad's `StockLaunchCreated` from the
  canonical receipt and checks it against the reviewed arguments and the
  launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @binding_keys [:launchpad, :hook, :bid_adapter, :agent_strategy, :usdc, :permit2]
  @subject_selector "0x0a59a98c"
  @splitter_index 14

  def binding_keys, do: @binding_keys

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{stock: stock, subject_splitter: candidate}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, header} <- block_header(block, opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :launchpad), block, opts),
         {:ok, paused} <- launchpad_bool(config, "launchesPaused()", [], block, opts),
         {:ok, [admitted, decimals, route]} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, route} <- Abi.word_address(route) |> allow_zero(route),
         {:ok, subject} <- subject_state(config, candidate, block, opts) do
      {:ok,
       %{
         launchpad: Lab.address!(config, :launchpad),
         hook: Lab.address!(config, :hook),
         paused: paused,
         block: Map.put(block, :timestamp, header.timestamp),
         admission: %{admitted: admitted != 0, decimals: decimals, route: route},
         subject: subject,
         lab_binding: Lab.binding(config, @binding_keys)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @spec verify(map(), :launch, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, :launch, hash) do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_stocks_launch",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         [step] <- envelope["arguments"]["steps"],
         {:ok, evidence} <- LabRpc.canonical_outcome_evidence(config, envelope, step, hash),
         {:ok, result} <- settled(evidence.outcome, envelope, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  # Subject lane evidence that does not depend on the launchpad's own
  # `subjectConfig`: the candidate names a subject, the Agent strategy names that
  # subject's auction, and the strategy's distribution record for that auction
  # names the candidate as its splitter.
  defp subject_state(_config, nil, _block, _opts), do: {:ok, :off}

  defp subject_state(config, candidate, block, opts) do
    strategy = Lab.address!(config, :agent_strategy)

    with :ok <- LabRpc.ensure_contract(candidate, block, opts),
         {:ok, subject} <- Rpc.call_address(candidate, @subject_selector, block, opts),
         {:ok, auction} <-
           Rpc.call_address(
             strategy,
             LabAbi.encode(agent_strategy_abi(config), "auctionOfSubject(address)", [subject]),
             block,
             opts
           ),
         {:ok, words} <-
           Rpc.call_words(
             strategy,
             LabAbi.encode(agent_strategy_abi(config), "distribution(address)", [auction]),
             block,
             18,
             opts
           ),
         {:ok, splitter} <- Abi.word_address(Enum.at(words, @splitter_index)) do
      {:ok, if(Address.equal?(splitter, candidate), do: :verified, else: :unverified)}
    else
      {:error, :lab_contract_missing} -> {:ok, :unverified}
      :error -> {:ok, :unverified}
      {:error, :invalid_chain_response} -> {:ok, :unverified}
      {:error, reason} -> {:error, reason}
    end
  end

  # The Agent strategy ABI lives in the Agent lab configuration this Stocks lab
  # extends; the Stocks file repeats only its address.
  defp agent_strategy_abi(_config), do: Autolaunch.Lab.abi!(Autolaunch.Lab.current!(), :strategy)

  defp settled(:pending, _envelope, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, envelope, config) do
    arguments = envelope["arguments"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, envelope["expected_signer"]),
         true <- Address.equal?(event.stock, arguments["stock"]),
         true <- Address.equal?(event.fee_administrator, arguments["fee_administrator"]),
         true <- event.start_block == integer(arguments, "start_block"),
         true <- event.floor_price_q96 == integer(arguments, "floor_price_q96"),
         true <- event.required_stock_raised == integer(arguments, "required_stock_raised"),
         opts <- Lab.rpc_opts(config),
         {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [event.launch_id],
             StocksLabAbi.launch_record_words(),
             block,
             opts
           ),
         true <- record_matches?(record, event),
         {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [event.auction], block, opts),
         true <- launch_id == event.launch_id do
      {:ok,
       %{
         outcome: :confirmed,
         result: %{
           "launch_id" => Integer.to_string(event.launch_id),
           "new_token" => event.new_token,
           "auction" => event.auction,
           "stock" => event.stock,
           "fee_administrator" => event.fee_administrator,
           "start_block" => Integer.to_string(event.start_block),
           "end_block" => Integer.to_string(event.end_block),
           "auction_inventory" => Integer.to_string(event.auction_inventory),
           "migration_reserve" => Integer.to_string(event.migration_reserve),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp launch_created(logs, config) do
    with {:ok, {[launch_id, launcher_word, new_token_word], data}} <-
           LabAbi.event_words(
             Lab.abi!(config, :launchpad),
             StocksLabAbi.launch_created_signature(),
             logs,
             Lab.address!(config, :launchpad)
           ),
         [
           stock_word,
           auction_word,
           admin_word,
           start_block,
           end_block,
           floor,
           required,
           inventory,
           reserve
         ] <- data,
         {:ok, launcher} <- Abi.word_address(launcher_word),
         {:ok, new_token} <- Abi.word_address(new_token_word),
         {:ok, stock} <- Abi.word_address(stock_word),
         {:ok, auction} <- Abi.word_address(auction_word),
         {:ok, fee_administrator} <- Abi.word_address(admin_word) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         new_token: new_token,
         stock: stock,
         auction: auction,
         fee_administrator: fee_administrator,
         start_block: start_block,
         end_block: end_block,
         floor_price_q96: floor,
         required_stock_raised: required,
         auction_inventory: inventory,
         migration_reserve: reserve
       }}
    else
      _ -> :error
    end
  end

  # `launches(launchId)`: launcher, newToken, stock, auction, feeAdministrator,
  # startBlock, endBlock, claimBlock, migrationBlock, requiredStockRaised,
  # floorPriceQ96, lifecycle, ...
  defp record_matches?(
         [launcher, new_token, stock, auction, admin, start_block, end_block | _rest] = record,
         event
       )
       when is_list(record) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, new_token} <- Abi.word_address(new_token),
         {:ok, stock} <- Abi.word_address(stock),
         {:ok, auction} <- Abi.word_address(auction),
         {:ok, admin} <- Abi.word_address(admin) do
      Enum.all?(
        [
          {launcher, event.launcher},
          {new_token, event.new_token},
          {stock, event.stock},
          {auction, event.auction},
          {admin, event.fee_administrator}
        ],
        fn {left, right} -> Address.equal?(left, right) end
      ) and start_block == event.start_block and end_block == event.end_block and
        Enum.at(record, 9) == event.required_stock_raised and
        Enum.at(record, 10) == event.floor_price_q96
    else
      _ -> false
    end
  end

  defp record_matches?(_record, _event), do: false

  defp block_header(%{number: number}, opts) do
    with {:ok, %{"timestamp" => "0x" <> hex}} <-
           Rpc.request(
             "eth_getBlockByNumber",
             ["0x" <> Integer.to_string(number, 16), false],
             opts
           ),
         {timestamp, ""} <- Integer.parse(hex, 16) do
      {:ok, %{timestamp: timestamp}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_block_header}
    end
  end

  defp launchpad_bool(config, signature, arguments, block, opts) do
    Rpc.call_bool(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :launchpad),
      LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments),
      block,
      count,
      opts
    )
  end

  # A revoked stock answers with the zero route, which is not an address but is
  # a truthful part of the admission record.
  defp allow_zero({:ok, address}, _word), do: {:ok, address}
  defp allow_zero(:error, 0), do: {:ok, nil}
  defp allow_zero(:error, _word), do: :error

  defp integer(arguments, key), do: arguments |> Map.fetch!(key) |> String.to_integer()
end
