defmodule Autolaunch.Stocks.LabLaunchChainClient do
  @moduledoc """
  The one fork boundary a Stocks launch has: one snapshot before review, one
  read after the hash.

  `snapshot/1` answers at one latest block: the launchpad's pause state and the
  admission record of the chosen STOCK. `verify/3` decodes the launchpad's
  `StockLaunchCreated` from the canonical receipt and checks it against the
  reviewed arguments and the launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @binding_keys [:launchpad, :hook, :bid_adapter, :usdc, :permit2]

  def binding_keys, do: @binding_keys

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{stock: stock}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :launchpad), block, opts),
         {:ok, paused} <- launchpad_bool(config, "launchesPaused()", [], block, opts),
         {:ok, [admitted, decimals, route]} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, route} <- Abi.word_address(route) |> allow_zero(route) do
      {:ok,
       %{
         launchpad: Lab.address!(config, :launchpad),
         hook: Lab.address!(config, :hook),
         paused: paused,
         block: block,
         admission: %{admitted: admitted != 0, decimals: decimals, route: route},
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
         %{} = current <- current_step(envelope, :launch),
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

  # The launch is confirmed only when the launchpad's event names the reviewed
  # signer, STOCK, floor and required raise, and its own record and auction
  # index agree with that event. The start and end blocks are the launchpad's
  # own: bidding opens a fixed lead after the block the launch was created in.
  defp settled({:success, logs}, envelope, config) do
    arguments = envelope["arguments"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, envelope["expected_signer"]),
         true <- Address.equal?(event.stock, arguments["stock"]),
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
           "start_block" => Integer.to_string(event.start_block),
           "end_block" => Integer.to_string(event.end_block),
           "required_stock_raised" => Integer.to_string(event.required_stock_raised),
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
         [stock_word, auction_word, start_block, end_block, floor, required, inventory, reserve] <-
           data,
         {:ok, launcher} <- Abi.word_address(launcher_word),
         {:ok, new_token} <- Abi.word_address(new_token_word),
         {:ok, stock} <- Abi.word_address(stock_word),
         {:ok, auction} <- Abi.word_address(auction_word) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         new_token: new_token,
         stock: stock,
         auction: auction,
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

  # `launches(launchId)`: launcher, newToken, stock, auction, splitter (zero
  # until graduation), startBlock, endBlock, claimBlock, migrationBlock,
  # requiredStockRaised, floorPriceQ96, lifecycle, ...
  defp record_matches?(
         [launcher, new_token, stock, auction, _splitter, start_block, end_block | _rest] = record,
         event
       )
       when is_list(record) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, new_token} <- Abi.word_address(new_token),
         {:ok, stock} <- Abi.word_address(stock),
         {:ok, auction} <- Abi.word_address(auction) do
      Enum.all?(
        [
          {launcher, event.launcher},
          {new_token, event.new_token},
          {stock, event.stock},
          {auction, event.auction}
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
