defmodule Autolaunch.Robinhood.StocksLaunchChainClient do
  @moduledoc """
  The one chain boundary a Robinhood memestock launch has: one snapshot before
  review, one read after the hash.

  `snapshot/1` answers at one latest block: the Stocks launchpad's pause state
  and the admission record of the chosen STOCK. `verify/3` decodes the
  launchpad's `StockLaunchCreated` from the canonical receipt and checks it
  against the reviewed arguments and the launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  @binding_keys [:stocks_launchpad, :stocks_hook, :bid_adapter]

  def binding_keys, do: @binding_keys

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{stock: stock}) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         :ok <- LabRpc.ensure_contract(Lab.address!(config, :stocks_launchpad), block, opts),
         {:ok, paused} <- launchpad_bool(config, "launchesPaused()", [], block, opts),
         {:ok, words} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, admission} <- admission(words) do
      {:ok,
       %{
         launchpad: Lab.address!(config, :stocks_launchpad),
         hook: Lab.address!(config, :stocks_hook),
         paused: paused,
         block: block,
         admission: admission,
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
             resource: "autolaunch_robinhood_stocks_launch",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         %{} = current <- current_step(envelope, :launch),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, evidence} <-
           Rpc.canonical_outcome_evidence(
             hash,
             envelope["expected_signer"],
             current["to"],
             current["data"],
             block,
             opts
           ),
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
    opts = Lab.rpc_opts(config)

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, envelope["expected_signer"]),
         true <- Address.equal?(event.stock, arguments["stock"]),
         true <- event.floor_price_q96 == integer(arguments, "floor_price_q96"),
         true <- event.required_stock_raised == integer(arguments, "required_stock_raised"),
         {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [event.launch_id],
             RobinhoodLabAbi.launch_record_words(),
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
             Lab.abi!(config, :stocks_launchpad),
             RobinhoodLabAbi.stock_launch_created_signature(),
             logs,
             Lab.address!(config, :stocks_launchpad)
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

  # `launches(launchId)`: launcher, newToken, currency (the STOCK), auction,
  # startBlock, endBlock, claimBlock, migrationBlock, requiredRaise,
  # floorPriceQ96, lifecycle, poolId, finalSqrtPriceX96, splitter, ...
  defp record_matches?(
         [launcher, new_token, currency, auction, start_block, end_block | _rest] = record,
         event
       ) do
    with {:ok, launcher} <- Abi.word_address(launcher),
         {:ok, new_token} <- Abi.word_address(new_token),
         {:ok, currency} <- Abi.word_address(currency),
         {:ok, auction} <- Abi.word_address(auction) do
      Address.equal?(launcher, event.launcher) and Address.equal?(new_token, event.new_token) and
        Address.equal?(currency, event.stock) and Address.equal?(auction, event.auction) and
        start_block == event.start_block and end_block == event.end_block and
        Enum.at(record, 8) == event.required_stock_raised and
        Enum.at(record, 9) == event.floor_price_q96
    else
      _ -> false
    end
  end

  defp record_matches?(_record, _event), do: false

  defp launchpad_bool(config, signature, arguments, block, opts) do
    Rpc.call_bool(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      count,
      opts
    )
  end

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  # `stockAdmission(stock)`: admitted, decimals, route. A stock that was never
  # admitted answers false, 0 and the zero route; a revoked stock answers false
  # with the decimals and route it was admitted with. An admitted stock always
  # has a route, so admitted with the zero route is not a chain answer.
  defp admission([admitted, decimals, route])
       when admitted in [0, 1] and decimals in 0..255 do
    case {admitted, Abi.word_address(route), route} do
      {1, {:ok, route}, _word} -> {:ok, %{admitted: true, decimals: decimals, route: route}}
      {0, {:ok, route}, _word} -> {:ok, %{admitted: false, decimals: decimals, route: route}}
      {0, :error, 0} -> {:ok, %{admitted: false, decimals: decimals, route: nil}}
      _other -> :error
    end
  end

  defp admission(_words), do: :error

  defp integer(arguments, key), do: arguments |> Map.fetch!(key) |> String.to_integer()
end
