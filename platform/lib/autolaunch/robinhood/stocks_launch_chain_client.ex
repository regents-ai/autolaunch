defmodule Autolaunch.Robinhood.StocksLaunchChainClient do
  @moduledoc """
  The one chain boundary a Robinhood memestock launch has: one snapshot before
  review, one read after the hash.

  `snapshot/1` answers at one latest block: the Stocks launchpad's pause state
  and the admission record of the chosen STOCK. `verify/2` decodes the
  launchpad's `StockLaunchCreated` from the receipt of a review's launch step
  and checks it against the reviewed facts and the launchpad's own record.
  """

  alias Autolaunch.Chain.{Abi, Rpc}

  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias RegentChain.Address

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
         admission: admission
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @doc """
  Whether `hash` is `signer`'s transaction of the launch `step`, and the launch
  it created is the one `facts` reviewed.
  """
  @spec verify(String.t(), map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(signer, %{to: to, data: data}, facts, hash) do
    with {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, outcome} <- Rpc.canonical_outcome(hash, signer, to, data, block, opts),
         do: settled(outcome, signer, facts, config)
  end

  defp settled(:pending, _signer, _facts, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _signer, _facts, _config), do: {:ok, %{outcome: :reverted}}

  # The launch is confirmed only when the launchpad's event names the reviewed
  # signer and STOCK, and its own record and auction index agree with that
  # event. The floor and the required raise are the launchpad's fixed preset. The start and end blocks are the launchpad's
  # own: bidding opens a fixed lead after the block the launch was created in.
  defp settled({:success, logs}, signer, facts, config) do
    opts = Lab.rpc_opts(config)

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, event} <- launch_created(logs, config),
         true <- Address.equal?(event.launcher, signer),
         true <- Address.equal?(event.stock, facts["stock"]),
         shape = RobinhoodLabAbi.shape(:v2),
         {:ok, words} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [event.launch_id],
             shape.record_words,
             block,
             opts
           ),
         true <- record_matches?(RobinhoodLabAbi.record(shape, words), event),
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
             Lab.abi!(config, :stocks_launchpad),
             RobinhoodLabAbi.stock_launch_created_signature(),
             logs,
             Lab.address!(config, :stocks_launchpad)
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
      [launcher: :launcher, new_token: :new_token, currency: :stock, auction: :auction],
      fn {field, key} ->
        record
        |> Map.fetch!(field)
        |> Abi.word_address()
        |> address_matches?(Map.fetch!(event, key))
      end
    ) and record.start_block == event.start_block and record.end_block == event.end_block
  end

  defp address_matches?({:ok, address}, expected), do: Address.equal?(address, expected)
  defp address_matches?(:error, _expected), do: false

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
end
