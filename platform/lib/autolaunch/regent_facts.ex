defmodule Autolaunch.RegentFacts do
  @moduledoc """
  What the REGENT page shows: supply, staking and USDC revenue, read from Base
  mainnet at one `safe` block, plus the REGENT price for the circulating market
  cap. It is the same count regents.sh/stake shows.

  Circulating supply is the total less the four holdings nobody can spend
  today: the Clanker vault, the treasury the staking contract names, the Animata
  redeemer and the staking contract's REGENT reward inventory.

  One reading is kept for a minute and shared by every visitor. It is taken
  inside this process, so visitors who ask while it is being taken wait for that
  one reading instead of each starting their own. The seven days of USDC and
  the price are read beside the rest; either one that does not answer is
  `:unavailable` and the rest of the reading stands.
  """

  use GenServer

  require Logger

  alias Autolaunch.Chain.Abi
  alias Autolaunch.Chain.Address
  alias Autolaunch.Chain.Rpc

  @manifest_path Path.expand("../../contracts/chain-contracts.yaml", __DIR__)
  @external_resource @manifest_path

  @manifest YamlElixir.read_from_file!(@manifest_path)
  @staking Enum.find(
             get_in(@manifest, ["contracts", Access.at(0), "reviewed_action_evidence"]),
             &(&1["contract_id"] == "regent_revenue_staking")
           )

  @clanker_vault "0x8e845ead15737bf71904a30bddd3aee76d6adf6c"
  @animata_redeemer "0x71065b775a590c43933F10c0055dc7d74AfAbb0e"
  # The Uniswap pool REGENT trades in, as DexScreener names it.
  @pool "0x4ed3b69ac263ad86482f609b2c2105f64bcfd3a7e02e8e078ec9fec1f0324bed"

  @regent_decimals 18
  @usdc_decimals 6

  # totalSupply()
  @total_supply "0x18160ddd"
  # totalUsdcReceived()
  @total_usdc_received "0xcf51bfdd"
  # emissionAprBps()
  @emission_apr_bps "0x8ba7fda0"
  # treasuryRecipient()
  @treasury_recipient "0xeb4eebc7"
  # availableRegentRewardInventory()
  @reward_inventory "0xe2cfe6b9"
  # allocation(address): token, amount, claimed, lockedUntil, vestedBy, admin
  @vault_allocation "0xb81b8630"
  # USDCRevenueDeposited(uint256,uint256,uint256,uint8,address,bytes32,bytes32):
  # three indexed topics, then amountReceived first of four data words.
  @usdc_deposited "0x1a150e3db61cdcdf841d24acf00159c2e184f84c02c7ec5ab3507766dae59e51"

  # Base makes a block about every two seconds, so seven days is 302,400 of
  # them, counted back from the block the rest of the reading was taken at. A
  # public Base endpoint answers `eth_getLogs` over at most ten thousand blocks,
  # so the window is asked for in that many at a time, a few at a time.
  @window_blocks 302_400
  @chunk_blocks 10_000
  @chunk_concurrency 8

  @ttl_ms 60_000
  @read_timeout 30_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(options, :name, __MODULE__))

  @doc "The Uniswap pool REGENT trades in."
  def pool, do: @pool

  @doc "The shared REGENT reading, at most a minute old."
  @spec read() :: {:ok, map()} | {:error, atom()}
  def read, do: GenServer.call(__MODULE__, :read, @read_timeout)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(:read, _from, {reading, read_at} = kept) when is_map(reading) do
    if read_at + @ttl_ms > now(), do: {:reply, {:ok, reading}, kept}, else: reread(kept)
  end

  def handle_call(:read, _from, nil), do: reread(nil)

  defp reread(kept) do
    case read_base() do
      {:ok, reading} -> {:reply, {:ok, reading}, {reading, now()}}
      {:error, reason} -> {:reply, {:error, reason}, kept}
    end
  end

  defp read_base do
    token = Abi.regent_address()
    staking = @staking["address"]

    with {:ok, block} <- Rpc.safe_block(),
         {:ok, stake_token} <- Rpc.call_address(staking, staking_selector("stake_token"), block),
         :ok <- match_stake_token(stake_token, token),
         {:ok, total_supply} <- Rpc.call_uint(token, @total_supply, block),
         {:ok, total_staked} <- Rpc.call_uint(staking, staking_selector("total_staked"), block),
         {:ok, usdc_received} <- Rpc.call_uint(staking, @total_usdc_received, block),
         {:ok, apr_bps} <- Rpc.call_uint(staking, @emission_apr_bps, block),
         {:ok, treasury} <- Rpc.call_address(staking, @treasury_recipient, block),
         {:ok, treasury_held} <- balance_of(token, treasury, block),
         {:ok, inventory} <- Rpc.call_uint(staking, @reward_inventory, block),
         {:ok, redeemer_held} <- balance_of(token, @animata_redeemer, block),
         {:ok, vault_held} <- balance_of(token, @clanker_vault, block),
         {:ok, [_token, _amount, _claimed, locked_until, vested_by, _admin]} <-
           Rpc.call_words(@clanker_vault, @vault_allocation <> address_word(token), block, 6) do
      circulating =
        max(total_supply - vault_held - treasury_held - redeemer_held - inventory, 0)

      {:ok,
       %{
         block_number: block.number,
         token_address: token,
         staking_address: staking,
         total_supply: regent(total_supply),
         total_staked: regent(total_staked),
         circulating_supply: regent(circulating),
         staked_share_bps: share_bps(total_staked, circulating),
         usdc_received_lifetime: Rpc.format_units(usdc_received, @usdc_decimals),
         usdc_received_7d: usdc_received_7d(staking, block.number),
         emission_apr_percent: Rpc.format_units(apr_bps, 2),
         price_usd: price_usd(token),
         clanker_vault: %{
           address: @clanker_vault,
           amount: regent(vault_held),
           locked_until: DateTime.from_unix!(locked_until),
           vested_by: DateTime.from_unix!(vested_by)
         },
         treasury: %{address: treasury, amount: regent(treasury_held)},
         animata_redeemer: %{address: @animata_redeemer, amount: regent(redeemer_held)},
         reward_inventory: %{address: staking, amount: regent(inventory)}
       }}
    end
  end

  defp regent(amount), do: Rpc.format_units(amount, @regent_decimals)

  defp share_bps(part, whole) when whole > 0 and part <= whole, do: div(part * 10_000, whole)
  defp share_bps(_part, _whole), do: :unavailable

  defp balance_of(token, holder, block),
    do: Rpc.call_uint(token, Abi.encode_erc20("balance_of", [holder]), block)

  defp address_word("0x" <> hex), do: hex |> String.downcase() |> String.pad_leading(64, "0")

  defp staking_selector(id) do
    @staking["reads"]
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("selector")
  end

  defp match_stake_token(actual, expected) do
    if Address.equal?(actual, expected), do: :ok, else: {:error, :stake_token_mismatch}
  end

  # Every USDC deposit the staking contract recorded over the seven days ending
  # at `to_block`, added up from its own logs. The first stretch that fails ends
  # the sum: a total made from the stretches that happened to answer would
  # understate what the contract received.
  defp usdc_received_7d(staking, to_block) do
    from_block = max(to_block - @window_blocks + 1, 0)

    from_block
    |> Stream.iterate(&(&1 + @chunk_blocks))
    |> Stream.take_while(&(&1 <= to_block))
    |> Task.async_stream(&stretch_received(staking, &1, min(&1 + @chunk_blocks - 1, to_block)),
      max_concurrency: @chunk_concurrency,
      timeout: @read_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:received, 0}, fn
      {:ok, {:ok, received}}, {:received, total} -> {:cont, {:received, total + received}}
      failed, _total -> {:halt, {:failed, failed}}
    end)
    |> case do
      {:received, received} ->
        Rpc.format_units(received, @usdc_decimals)

      {:failed, failed} ->
        Logger.warning("REGENT seven-day USDC unavailable: #{inspect(failed)}")
        :unavailable
    end
  end

  defp stretch_received(staking, from_block, to_block) do
    filter = %{
      address: staking,
      topics: [@usdc_deposited],
      fromBlock: quantity(from_block),
      toBlock: quantity(to_block)
    }

    case Rpc.request("eth_getLogs", [filter]) do
      {:ok, logs} when is_list(logs) -> sum_received(logs, staking)
      {:ok, _malformed} -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sum_received(logs, staking) do
    Enum.reduce_while(logs, {:ok, 0}, fn log, {:ok, total} ->
      case Abi.one_event([log], @usdc_deposited, staking, 3, 4) do
        {:ok, {_indexed, [received | _rest]}} -> {:cont, {:ok, total + received}}
        :error -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
  end

  defp quantity(value), do: "0x" <> String.downcase(Integer.to_string(value, 16))

  # DexScreener's USD price for the REGENT pool, trusted only when the pool's
  # base token is REGENT and the price is a plain decimal.
  defp price_usd(token) do
    client = Application.get_env(:autolaunch, :autolaunch_market_http_client, Req)

    with {:ok, %{status: 200, body: %{"pairs" => [pair | _]}}} <-
           client.get("https://api.dexscreener.com/latest/dex/pairs/base/#{@pool}",
             connect_options: [timeout: 3_000],
             receive_timeout: 5_000,
             retry: false
           ),
         %{"baseToken" => %{"address" => base}, "priceUsd" => price} when is_binary(price) <-
           pair,
         true <- Address.equal?(base, token),
         {_decimal, ""} <- Decimal.parse(price) do
      price
    else
      _unavailable -> :unavailable
    end
  rescue
    _error -> :unavailable
  end

  defp now, do: System.monotonic_time(:millisecond)
end
