defmodule Autolaunch.Stocks.LabLaunchChainClient do
  @moduledoc """
  The one fork boundary a Stocks launch has: one snapshot before review, one
  read after the hash.

  `snapshot/1` answers at one latest block: the launchpad's pause state and the
  admission record of the chosen STOCK. `verify/2` decodes the launchpad's
  `StockLaunchCreated` from the receipt of a saved review's step and checks it
  against the reviewed facts and the launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Rpc}

  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.Address

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
         admission: %{admitted: admitted != 0, decimals: decimals, route: route}
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @spec verify(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(%{"signer" => signer, "step" => step, "facts" => facts}, hash) do
    with {:ok, config} <- Lab.current(),
         {:ok, outcome} <- LabRpc.outcome(Lab.rpc_opts(config), signer, step, hash),
         do: settled(outcome, signer, facts, config)
  end

  defp settled(:pending, _signer, _facts, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _signer, _facts, _config), do: {:ok, %{outcome: :reverted}}

  # The launch is confirmed only when the launchpad's event names the reviewed
  # signer and STOCK, and its own record and auction index agree with that
  # event. The floor and the required raise are the launchpad's fixed preset.
  # The start and end blocks are the launchpad's own: bidding opens a fixed
  # lead after the block the launch was created in.
  defp settled({:success, logs}, signer, facts, config) do
    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, signer),
         true <- Address.equal?(event.stock, facts["stock"]),
         opts <- Lab.rpc_opts(config),
         shape = StocksLabAbi.shape(:v2),
         {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [event.launch_id],
             shape.record_words,
             block,
             opts
           ),
         true <- record_matches?(StocksLabAbi.record(shape, words), event),
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
           "auction_inventory" => Integer.to_string(event.auction_inventory),
           "migration_reserve" => Integer.to_string(event.migration_reserve),
           "creator_vesting" => Integer.to_string(event.creator_vesting),
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
         [stock_word, auction_word, start_block, end_block, inventory, reserve, vesting] <- data,
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
         auction_inventory: inventory,
         migration_reserve: reserve,
         creator_vesting: vesting
       }}
    else
      _ -> :error
    end
  end

  defp record_matches?(record, event) do
    Enum.all?(
      [:launcher, :new_token, :stock, :auction],
      &(Abi.word_address(Map.fetch!(record, &1)) |> address_matches?(Map.fetch!(event, &1)))
    ) and record.start_block == event.start_block and record.end_block == event.end_block
  end

  defp address_matches?({:ok, address}, expected), do: Address.equal?(address, expected)
  defp address_matches?(:error, _expected), do: false

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
end
