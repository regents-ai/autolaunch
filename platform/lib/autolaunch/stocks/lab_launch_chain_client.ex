defmodule Autolaunch.Stocks.LabLaunchChainClient do
  @moduledoc """
  The one fork boundary a Stocks launch has: one snapshot before review, one
  read after the hash.

  `snapshot/1` answers at one latest block: the launchpad's pause state and
  launch fee, the signer's REGENT balance and allowance to the launchpad, the
  admission record of the chosen STOCK, and, when a subject lane is requested,
  whether the candidate splitter is the one the Agent strategy recorded for its
  own subject. `verify/3` reads the allowance back for the approval step, and
  for the launch step decodes the launchpad's `StockLaunchCreated` and
  `StockLaunchFeeCollected` from the canonical receipt and checks them against
  the reviewed arguments and the launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @binding_keys [:launchpad, :hook, :bid_adapter, :agent_strategy, :usdc, :permit2, :regent]
  @subject_selector "0x0a59a98c"
  @splitter_index 14

  def binding_keys, do: @binding_keys

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{stock: stock, subject_splitter: candidate, signer: signer}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, header} <- block_header(block, opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :launchpad), block, opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :regent), block, opts),
         {:ok, paused} <- launchpad_bool(config, "launchesPaused()", [], block, opts),
         {:ok, fee} <- launchpad_uint(config, "launchFee()", [], block, opts),
         {:ok, balance} <- regent_uint(config, "balanceOf(address)", [signer], block, opts),
         {:ok, allowance} <- allowance(config, signer, block, opts),
         {:ok, [admitted, decimals, route]} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, route} <- Abi.word_address(route) |> allow_zero(route),
         {:ok, subject} <- splitter_state(config, candidate, block, opts) do
      {:ok,
       %{
         launchpad: Lab.address!(config, :launchpad),
         hook: Lab.address!(config, :hook),
         regent: Lab.address!(config, :regent),
         paused: paused,
         fee: fee,
         balance: balance,
         allowance: allowance,
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

  @spec verify(map(), :approval | :launch, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) when step in [:approval, :launch] do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_stocks_launch",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         %{} = current <- current_step(envelope, step),
         {:ok, evidence} <- LabRpc.canonical_outcome_evidence(config, envelope, current, hash),
         {:ok, result} <- settled(evidence.outcome, envelope, step, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @doc """
  Whether a candidate subject splitter is authentic: `:off` for no candidate,
  `:verified` when the candidate names a subject, the Agent strategy names that
  subject's auction, and the strategy's distribution record for that auction
  names the candidate as its splitter; `:unverified` otherwise. This is the same
  rule the launchpad enforces, answered before a wallet is asked. The fee
  administration lane reuses it for a retargeted lane.
  """
  @spec splitter_state(map(), String.t() | nil, map(), keyword()) ::
          {:ok, :off | :verified | :unverified} | {:error, atom()}
  def splitter_state(_config, nil, _block, _opts), do: {:ok, :off}

  def splitter_state(config, candidate, block, opts) do
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

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  # The allowance correction is confirmed only when the token recorded exactly
  # the reviewed approval and the standing allowance now equals it.
  defp settled({:success, logs}, envelope, :approval, config) do
    signer = envelope["expected_signer"]
    amount = envelope |> current_step(:approval) |> Map.fetch!("amount") |> String.to_integer()

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         true <-
           Abi.approval_recorded?(
             logs,
             Lab.address!(config, :regent),
             signer,
             Lab.address!(config, :launchpad),
             amount
           ),
         {:ok, allowance} <- allowance(config, signer, block, Lab.rpc_opts(config)) do
      {:ok, %{outcome: if(allowance == amount, do: :confirmed, else: :unverified)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settled({:success, logs}, envelope, :launch, config) do
    arguments = envelope["arguments"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, envelope["expected_signer"]),
         true <- Address.equal?(event.stock, arguments["stock"]),
         true <- Address.equal?(event.fee_administrator, arguments["fee_administrator"]),
         true <- event.start_block == integer(arguments, "start_block"),
         true <- event.floor_price_q96 == integer(arguments, "floor_price_q96"),
         true <- event.required_stock_raised == integer(arguments, "required_stock_raised"),
         {:ok, fee} <-
           fee_collected(logs, config, event.launch_id, envelope["expected_signer"]),
         true <- fee == integer(arguments, "expected_launch_fee_atomic"),
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
           "launch_fee" => Integer.to_string(fee),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The fee the launchpad recorded for this exact launch, paid by the signer. The
  # launchpad emits nothing for a zero fee, so a zero review is satisfied by the
  # absence of the event.
  defp fee_collected(logs, config, launch_id, signer) do
    launchpad = Lab.address!(config, :launchpad)
    abi = Lab.abi!(config, :launchpad)

    case LabAbi.event_words(abi, StocksLabAbi.fee_collected_signature(), logs, launchpad) do
      {:ok, {[^launch_id, payer_word, _staking_word], [amount]}} ->
        with {:ok, payer} <- Abi.word_address(payer_word),
             true <- Address.equal?(payer, signer),
             do: {:ok, amount},
             else: (_ -> :error)

      {:ok, _other_launch} ->
        :error

      :error ->
        {:ok, 0}
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

  # REGENT is read through the configuration's standard `erc20` ABI at the
  # address the Stocks lab repeats from the Agent lab.
  defp regent_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :regent),
      LabAbi.encode(Lab.abi!(config, :erc20), signature, arguments),
      block,
      opts
    )
  end

  defp allowance(config, signer, block, opts) do
    regent_uint(
      config,
      "allowance(address,address)",
      [signer, Lab.address!(config, :launchpad)],
      block,
      opts
    )
  end

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  # A revoked stock answers with the zero route, which is not an address but is
  # a truthful part of the admission record.
  defp allow_zero({:ok, address}, _word), do: {:ok, address}
  defp allow_zero(:error, 0), do: {:ok, nil}
  defp allow_zero(:error, _word), do: :error

  defp integer(arguments, key), do: arguments |> Map.fetch!(key) |> String.to_integer()
end
