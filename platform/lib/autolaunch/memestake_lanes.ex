defmodule Autolaunch.MemestakeLanes do
  @moduledoc """
  Memestake's REGENT lane on each chain, stage by stage, as the REGENT page
  shows it: every amount read from the chain at that chain's latest block.

  On Base, every graduated memestock pool's hook holds the lane's stock until
  Regent's settling wallet swaps it to USDC and pays it into REGENT staking in
  one step. On Robinhood Chain the swap pays USDG into the protocol revenue
  inbox; the inbox sends batches over the bridge to its Base receiver, which
  pays what arrived into REGENT staking. The bridge stages exist only once
  the inbox names its Base receiver.

  Stock amounts stay per stock and are never added across stocks. Each chain
  is read on its own: one that does not answer is `:unavailable` and the
  other stands. Nothing here writes, signs or caches.
  """

  alias Autolaunch.Chain.Rpc
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @dollar_decimals 6

  @type stock_amount :: %{symbol: String.t(), amount: String.t()}
  @type base :: %{
          block: non_neg_integer(),
          waiting: [stock_amount()],
          converted: [stock_amount()],
          paid_usdc: String.t()
        }
  @type robinhood :: %{
          block: non_neg_integer(),
          waiting: [stock_amount()],
          converted: [stock_amount()],
          collected_usdg: String.t(),
          held_usdg: String.t(),
          bridge: :not_set_up | bridge()
        }
  @type bridge :: %{
          sent_usdg: String.t(),
          base_block: non_neg_integer(),
          arrived_usdc: String.t(),
          paid_usdc: String.t()
        }

  @doc "Base's lane, or nil when this site has no Base memestock deployment."
  @spec base() :: {:ok, base() | nil} | {:error, atom()}
  def base do
    if StocksLab.configured?() do
      with {:ok, tokens} <- Autolaunch.list_tokens(actor: nil),
           {:ok, config} <- StocksLab.current(),
           opts = StocksLab.rpc_opts(config, "autolaunch regent page"),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, lanes} <-
             tokens
             |> Enum.filter(&graduated_memestock?/1)
             |> collect(&base_lane(&1.auction, config, block, opts)) do
        {:ok,
         %{
           block: block.number,
           waiting: per_stock(lanes, :accrued_atomic),
           converted: per_stock(lanes, :settled_currency_atomic),
           paid_usdc: dollars(lanes)
         }}
      end
    else
      {:ok, nil}
    end
  end

  @doc "Robinhood Chain's lane, or nil when this site has no Robinhood deployment."
  @spec robinhood() :: {:ok, robinhood() | nil} | {:error, atom()}
  def robinhood do
    if RobinhoodLab.configured?() do
      with {:ok, config} <- RobinhoodLab.current(),
           opts = RobinhoodLab.rpc_opts(config),
           {:ok, block} <- Rpc.latest_block(opts),
           {:ok, launches} <- RobinhoodPool.graduated(config, block, opts),
           {:ok, lanes} <-
             collect(launches, &RobinhoodPool.regent_lane(&1, config, block, opts)),
           {:ok, inboxes} <- inboxes(config, block, opts),
           {:ok, bridge} <- bridge(inboxes) do
        {:ok,
         %{
           block: block.number,
           waiting: per_stock(lanes, :accrued_atomic),
           converted: per_stock(lanes, :settled_currency_atomic),
           collected_usdg: inboxes |> sum(:collected) |> Rpc.format_units(@dollar_decimals),
           held_usdg: inboxes |> sum(:held) |> Rpc.format_units(@dollar_decimals),
           bridge: bridge
         }}
      end
    else
      {:ok, nil}
    end
  end

  # A row whose auction contract does not exist at this head (a launch from an
  # earlier lab run) has nothing to read; the market feeds skip it the same way.
  defp base_lane(auction, config, block, opts) do
    case LabRpc.ensure_contract(auction.auction_address, block, opts) do
      :ok -> Pool.regent_lane(auction, config, block, opts)
      {:error, :lab_contract_missing} -> {:ok, nil}
      error -> error
    end
  end

  defp graduated_memestock?(%{auction: %{kind: :stocks, state: :graduated}}), do: true
  defp graduated_memestock?(_token), do: false

  # Each launchpad version's hook names the inbox its lane pays; the first
  # and second launchpads may name different ones.
  defp inboxes(config, block, opts) do
    with {:ok, addresses} <-
           config
           |> RobinhoodLab.versions()
           |> collect(&hook_inbox(config, &1, block, opts)) do
      addresses
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> collect(&inbox(&1, block, opts))
    end
  end

  defp hook_inbox(config, version, block, opts) do
    with {:ok, %{hook: hook}} <- RobinhoodLab.contracts(config, version),
         do: Rpc.call_address(hook, LabAbi.selector("inbox()"), block, opts)
  end

  defp inbox(address, block, opts) do
    with {:ok, collected} <- uint(address, "totalCollected()", block, opts),
         {:ok, held} <- uint(address, "available()", block, opts),
         {:ok, bridged} <- uint(address, "totalBridged()", block, opts),
         {:ok, destination} <- uint(address, "baseDestination()", block, opts) do
      {:ok, %{collected: collected, held: held, bridged: bridged, destination: destination}}
    end
  end

  # The Base receivers the inboxes send to, read on Base: what arrived and is
  # waiting to be paid in, and what they have paid into REGENT staking.
  defp bridge(inboxes) do
    case inboxes |> Enum.map(& &1.destination) |> Enum.reject(&(&1 == 0)) |> Enum.uniq() do
      [] -> {:ok, :not_set_up}
      receivers -> receivers(receivers, sum(inboxes, :bridged))
    end
  end

  defp receivers(receivers, bridged) do
    with {:ok, config} <- Lab.current(),
         opts = LabRpc.opts(config, "autolaunch regent page"),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, read} <- collect(receivers, &receiver(&1, block, opts)) do
      {:ok,
       %{
         sent_usdg: Rpc.format_units(bridged, @dollar_decimals),
         base_block: block.number,
         arrived_usdc: read |> sum(:arrived) |> Rpc.format_units(@dollar_decimals),
         paid_usdc: read |> sum(:paid) |> Rpc.format_units(@dollar_decimals)
       }}
    end
  end

  # A receiver as the inbox names it: an address word, never zero here.
  defp receiver(word, block, opts) do
    address =
      "0x" <> (word |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0"))

    with {:ok, usdc} <- Rpc.call_address(address, LabAbi.selector("usdc()"), block, opts),
         {:ok, arrived} <- uint(usdc, "balanceOf(address)", [address], block, opts),
         {:ok, paid} <- uint(address, "totalDeposited()", block, opts),
         do: {:ok, %{arrived: arrived, paid: paid}}
  end

  defp sum(items, field), do: items |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()

  defp uint(address, signature, block, opts), do: uint(address, signature, [], block, opts)

  defp uint(address, signature, arguments, block, opts) do
    data =
      Enum.reduce(arguments, LabAbi.selector(signature), fn argument, data ->
        data <> (argument |> String.trim_leading("0x") |> String.pad_leading(64, "0"))
      end)

    Rpc.call_uint(address, data, block, opts)
  end

  # Each stock's total over every pool that trades against it, largest first.
  defp per_stock(lanes, field) do
    lanes
    |> Enum.group_by(& &1.stock.address)
    |> Enum.map(fn {_address, [%{stock: stock} | _rest] = pools} ->
      atomic = pools |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum()
      {atomic, %{symbol: stock.symbol, amount: Rpc.format_units(atomic, stock.decimals)}}
    end)
    |> Enum.reject(fn {atomic, _amount} -> atomic == 0 end)
    |> Enum.sort_by(fn {atomic, amount} -> {-atomic, amount.symbol} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp dollars(lanes),
    do: lanes |> sum(:settled_usdc_atomic) |> Rpc.format_units(@dollar_decimals)

  defp collect(items, read) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, found} ->
      case read.(item) do
        {:ok, nil} -> {:cont, {:ok, found}}
        {:ok, lane} -> {:cont, {:ok, [lane | found]}}
        error -> {:halt, error}
      end
    end)
  end
end
