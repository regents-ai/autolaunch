defmodule Autolaunch.Stocks.Faucet do
  @moduledoc """
  Lab-only test funds: one fork transaction per press, sent by the site through
  Anvil's account impersonation, never signed by the customer.

  REGENT moves from the governance Safe's forked balance (Agent lab alone is
  enough; the launch-fee grant needs the Stocks lab's configured amount), STOCK
  is minted by the fixture token, and USDC moves from the forked holder the
  Stocks lab names. Every press sends; the RPC's own error text is reported when
  it fails. The RPC URL only ever comes from a validated lab configuration,
  which admits loopback alone, and a read-only site refuses.
  """

  alias Autolaunch.Chain.{Address, Rpc}
  alias Autolaunch.{Lab, LabAbi, Prelaunch}
  alias Autolaunch.Stocks.Amounts
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @regent_amount 1_000 * Integer.pow(10, 18)
  @gas_floor_wei 50_000_000_000_000_000
  @gas_grant_wei 1_000_000_000_000_000_000
  @receipt_attempts 20
  @receipt_wait_ms 250
  @timeout 8_000

  @type grant :: %{symbol: String.t(), amount: String.t(), balance: String.t(), hash: String.t()}

  @doc "Whether any lab that can fund a wallet is running on this site."
  def available? do
    not Prelaunch.read_only?() and (Lab.enabled?() or StocksLab.enabled?())
  end

  @doc "The STOCK tokens this lab can mint, for the button list."
  @spec stocks() :: [StocksLab.stock()]
  def stocks do
    case StocksLab.current() do
      {:ok, config} -> config.stocks
      {:error, _reason} -> []
    end
  end

  @doc "The launch-fee REGENT grant this lab offers, in whole REGENT for the button, or `nil`."
  @spec launch_fee_grant() :: String.t() | nil
  def launch_fee_grant do
    with {:ok, config} <- StocksLab.current(),
         amount when is_integer(amount) <- StocksLab.launch_fee_grant(config) do
      format(amount, 18)
    else
      _absent -> nil
    end
  end

  @doc "1,000 test REGENT from the governance Safe's forked balance."
  @spec regent(String.t()) :: {:ok, grant()} | {:error, String.t()}
  def regent(wallet), do: regent_grant(wallet, {:ok, @regent_amount})

  @doc "The Stocks lab's configured launch-fee REGENT from the governance Safe's forked balance."
  @spec regent_launch_fee(String.t()) :: {:ok, grant()} | {:error, String.t()}
  def regent_launch_fee(wallet) do
    amount =
      with {:ok, config} <- stocks_lab(),
           amount when is_integer(amount) <- StocksLab.launch_fee_grant(config) do
        {:ok, amount}
      else
        nil -> {:error, "This lab does not fund the launch fee."}
        error -> error
      end

    regent_grant(wallet, amount)
  end

  defp regent_grant(wallet, amount) do
    with :ok <- admitted(),
         {:ok, wallet} <- address(wallet),
         {:ok, amount} <- amount,
         {:ok, config} <- agent_lab() do
      grant(%{
        rpc: rpc(config.rpc_url),
        holder: Lab.address!(config, :governance_safe),
        token: Lab.address!(config, :regent),
        data: transfer_calldata(wallet, amount),
        wallet: wallet,
        symbol: "REGENT",
        amount: amount,
        decimals: 18
      })
    end
  end

  @doc "The configured STOCK amount, minted by the fixture token at the catalog address."
  @spec stock(String.t(), String.t()) :: {:ok, grant()} | {:error, String.t()}
  def stock(wallet, stock_address) do
    with :ok <- admitted(),
         {:ok, wallet} <- address(wallet),
         {:ok, config} <- stocks_lab(),
         {:ok, agent} <- agent_lab(),
         {:ok, stock} <- lab_stock(config, stock_address),
         {:ok, amount} <- stock_amount(config, stock) do
      grant(%{
        rpc: rpc(config.rpc_url),
        holder: Lab.address!(agent, :governance_safe),
        token: stock.address,
        data: mint_calldata(wallet, amount),
        wallet: wallet,
        symbol: stock.symbol,
        amount: amount,
        decimals: stock.decimals
      })
    end
  end

  @doc "The configured USDC amount from the forked holder the lab names."
  @spec usdc(String.t()) :: {:ok, grant()} | {:error, String.t()}
  def usdc(wallet) do
    with :ok <- admitted(),
         {:ok, wallet} <- address(wallet),
         {:ok, config} <- stocks_lab() do
      amount = String.to_integer(config.faucet["usdc_amount"])

      grant(%{
        rpc: rpc(config.rpc_url),
        holder: config.faucet["usdc_holder"],
        token: StocksLab.address!(config, :usdc),
        data: transfer_calldata(wallet, amount),
        wallet: wallet,
        symbol: "USDC",
        amount: amount,
        decimals: 6
      })
    end
  end

  defp lab_stock(config, address) do
    case StocksLab.stock(config, address) do
      nil -> {:error, "That stock token is not part of this lab."}
      stock -> {:ok, stock}
    end
  end

  defp stock_amount(config, stock) do
    case Amounts.parse_units(config.faucet["stock_amount_units"], stock.decimals) do
      {:ok, amount} -> {:ok, amount}
      {:error, reason} -> {:error, "The configured faucet amount is invalid: #{reason}."}
    end
  end

  # One impersonated transaction, then its receipt, then the wallet's new balance.
  defp grant(%{rpc: rpc, holder: holder, token: token, data: data, wallet: wallet} = order) do
    # Anvil answers `anvil_impersonateAccount` with a null result; only an error
    # refuses the impersonation.
    with :ok <- fund_gas(rpc, holder),
         {:ok, _impersonated} <- rpc.("anvil_impersonateAccount", [holder]),
         {:ok, hash} when is_binary(hash) <-
           rpc.("eth_sendTransaction", [%{from: holder, to: token, data: data}]),
         _stopped <- rpc.("anvil_stopImpersonatingAccount", [holder]),
         :ok <- receipt(rpc, hash, @receipt_attempts),
         {:ok, balance} <- balance(rpc, token, wallet) do
      {:ok,
       %{
         symbol: order.symbol,
         amount: format(order.amount, order.decimals),
         balance: format(balance, order.decimals),
         hash: hash
       }}
    else
      {:ok, other} -> {:error, "The lab answered unexpectedly: #{inspect(other)}"}
      {:error, message} -> {:error, message}
    end
  end

  # An impersonated holder still pays gas; a forked balance below the floor is
  # topped up on the fork before the transfer.
  defp fund_gas(rpc, holder) do
    case rpc.("eth_getBalance", [holder, "latest"]) do
      {:ok, "0x" <> hex} -> top_up(rpc, holder, String.to_integer(hex, 16))
      {:error, message} -> {:error, message}
      _other -> {:error, "The lab did not report the holder's balance."}
    end
  end

  defp top_up(_rpc, _holder, balance) when balance >= @gas_floor_wei, do: :ok

  defp top_up(rpc, holder, _balance) do
    with {:ok, _} <-
           rpc.("anvil_setBalance", [holder, "0x" <> Integer.to_string(@gas_grant_wei, 16)]),
         do: :ok
  end

  defp receipt(_rpc, _hash, 0),
    do: {:error, "The transaction was sent but no receipt arrived yet."}

  defp receipt(rpc, hash, attempts) do
    case rpc.("eth_getTransactionReceipt", [hash]) do
      {:ok, %{"status" => "0x1"}} ->
        :ok

      {:ok, %{"status" => "0x0"}} ->
        {:error, "The transaction #{hash} reverted on the lab."}

      {:ok, nil} ->
        Process.sleep(@receipt_wait_ms)
        receipt(rpc, hash, attempts - 1)

      {:error, message} ->
        {:error, message}

      {:ok, _other} ->
        {:error, "The lab returned an unreadable receipt."}
    end
  end

  defp balance(rpc, token, wallet) do
    data = "0x70a08231" <> pad_address(wallet)

    case rpc.("eth_call", [%{to: token, data: data}, "latest"]) do
      {:ok, "0x" <> hex} when hex != "" -> {:ok, String.to_integer(hex, 16)}
      {:ok, _other} -> {:error, "The lab did not report the new balance."}
      {:error, message} -> {:error, message}
    end
  end

  # `transfer(address,uint256)` and the fixture token's `mint(address,uint256)`;
  # both selectors are fixed by their signatures, so no ABI entry is required.
  defp transfer_calldata(wallet, amount),
    do: LabAbi.selector("transfer(address,uint256)") <> pad_address(wallet) <> pad_uint(amount)

  defp mint_calldata(wallet, amount),
    do: LabAbi.selector("mint(address,uint256)") <> pad_address(wallet) <> pad_uint(amount)

  defp pad_address("0x" <> hex), do: String.pad_leading(String.downcase(hex), 64, "0")

  defp pad_uint(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  # A JSON-RPC caller that keeps the node's own error message. The URL is the
  # validated loopback URL of a lab configuration and nothing else.
  defp rpc(rpc_url) do
    fn method, params ->
      request = %{jsonrpc: "2.0", id: 1, method: method, params: params}
      client = Application.get_env(:autolaunch, :autolaunch_lab_http_client, Req)

      case client.post(rpc_url, json: request, receive_timeout: @timeout, retry: false) do
        {:ok, %{status: 200, body: %{"result" => result}}} ->
          {:ok, result}

        {:ok, %{body: %{"error" => %{"message" => message}}}} when is_binary(message) ->
          {:error, "#{method}: #{message}"}

        {:ok, %{status: status}} ->
          {:error, "#{method}: the lab answered with status #{status}."}

        {:error, %{__exception__: true} = error} ->
          {:error, "#{method}: #{Exception.message(error)}"}

        {:error, other} ->
          {:error, "#{method}: #{inspect(other)}"}
      end
    end
  end

  defp admitted do
    if available?(), do: :ok, else: {:error, "Test funds are only available on a local lab site."}
  end

  defp agent_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, "The local lab is not available: #{reason}."}
    end
  end

  defp stocks_lab do
    case StocksLab.current() do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, "The Stocks lab is not available: #{reason}."}
    end
  end

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, "Choose a wallet on this account first."}
    end
  end

  defp format(amount, decimals), do: Rpc.format_units(amount, decimals)
end
