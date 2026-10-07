defmodule Autolaunch.SwapActions do
  @moduledoc """
  The one boundary between a trader's wallet and a graduated token's pool, on
  Base or on Robinhood Chain.

  Preparation reads the pool's own facts and returns the steps the wallet
  sends in turn: at most the exact token allowance to Permit2, the exact
  Permit2 allowance to Uniswap's router, then the one exact-input swap they
  enable. Nothing is written anywhere. The chain is the only record of a
  trade: the page reads what the swap paid from its receipt.

  Every review binds to one of the wallets of the account the session lease
  names, read inside the lease at call time: the page's active wallet must be
  one the account links, never a guess.

  The quote comes from Uniswap's quoter through the pool's own hook, so it is
  already net of the pool's fees; nothing is subtracted from it a second time.
  The lowest amount the trade accepts and the deadline are exact limits the
  wallet signs; only today's quote is an estimate.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, Permit2Abi, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.{Amounts, FeeSchedule, LaunchOperations}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias RegentChain.{Address, Review}

  # Uniswap's own Base deployments; the local Base fork carries the same code.
  # The Robinhood deployment names its router and quoter itself.
  @base_router "0x6ff5693b99212da76ad316178a184ab56d299b43"
  @base_quoter "0x0d5e0f971ed27fbff6c2837bf31316121532048d"
  # V4_SWAP, then SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
  @commands "0x10"
  @v4_actions "0x060c0f"
  # Price protection: how far below today's quote the trade may settle, in
  # hundredths of a percent. The trader chooses between 1% and 10%.
  @protection_range 100..1_000
  # The router refuses the swap once this many seconds have passed since the review.
  @deadline_seconds 900
  # A Permit2 allowance is granted for thirty minutes, so one granted by a
  # review still outlives the deadline of the review built after it lands.
  @permit2_seconds 1800
  # The quoter negates the amount as an int128, so an input stays below 2^127.
  @max_input Integer.pow(2, 127) - 1
  @uint128_max Integer.pow(2, 128) - 1
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  @pool_key %{
    "type" => "tuple",
    "components" => [
      %{"name" => "currency0", "type" => "address"},
      %{"name" => "currency1", "type" => "address"},
      %{"name" => "fee", "type" => "uint24"},
      %{"name" => "tickSpacing", "type" => "int24"},
      %{"name" => "hooks", "type" => "address"}
    ]
  }
  @quoter_abi [
    %{
      "type" => "function",
      "name" => "quoteExactInputSingle",
      "stateMutability" => "nonpayable",
      "outputs" => [%{"type" => "uint256"}, %{"type" => "uint256"}],
      "inputs" => [
        %{
          "type" => "tuple",
          "components" => [
            @pool_key,
            %{"name" => "zeroForOne", "type" => "bool"},
            %{"name" => "exactAmount", "type" => "uint128"},
            %{"name" => "hookData", "type" => "bytes"}
          ]
        }
      ]
    }
  ]
  @router_abi [
    %{
      "type" => "function",
      "name" => "execute",
      "stateMutability" => "payable",
      "outputs" => [],
      "inputs" => [
        %{"name" => "commands", "type" => "bytes"},
        %{"name" => "inputs", "type" => "bytes[]"},
        %{"name" => "deadline", "type" => "uint256"}
      ]
    }
  ]
  # SWAP_EXACT_IN_SINGLE as each chain's router reads it. Base's router takes
  # (PoolKey, zeroForOne, amountIn, amountOutMinimum, hookData); Robinhood's is a
  # newer Uniswap build that reads a per-hop price limit before hookData, which
  # the site leaves at 0 (none): amountOutMinimum already protects the trade.
  @base_swap_params %{
    "type" => "tuple",
    "components" => [
      @pool_key,
      %{"name" => "zeroForOne", "type" => "bool"},
      %{"name" => "amountIn", "type" => "uint128"},
      %{"name" => "amountOutMinimum", "type" => "uint128"},
      %{"name" => "hookData", "type" => "bytes"}
    ]
  }
  @robinhood_swap_params %{
    "type" => "tuple",
    "components" => [
      @pool_key,
      %{"name" => "zeroForOne", "type" => "bool"},
      %{"name" => "amountIn", "type" => "uint128"},
      %{"name" => "amountOutMinimum", "type" => "uint128"},
      %{"name" => "minHopPriceX36", "type" => "uint256"},
      %{"name" => "hookData", "type" => "bytes"}
    ]
  }
  @currency_amount [%{"type" => "address"}, %{"type" => "uint256"}]

  @doc """
  The steps of one exact-input trade on a graduated launch's pool for
  `address`, one of the signed-in account's wallets, with the figures the page
  shows beside them and what it needs to read the swap's result. The launch is `%{chain: :base, auction: auction_row}` or
  `%{chain: :robinhood, auction: auction_row}`, as the staking actions name
  it. `:buy` spends the pool's currency for the token; `:sell` the reverse.
  `protection` is the price protection in percent, from 1 to 10, rounded to two
  decimal places.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(
        %{launch: launch, direction: direction, amount: amount, protection: protection},
        address,
        opts
      )
      when direction in [:buy, :sell] do
    with {:ok, protection} <- protection(protection),
         {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, pool} <- pool(launch),
         {:ok, venue} <- venue(pool),
         trade <- trade(pool, direction),
         {:ok, amount_in} <- amount_in(amount, trade.sell.decimals),
         {:ok, snapshot} <- snapshot(trade, signer, amount_in, pool.block, venue),
         {:ok, min_out} <- min_out(snapshot.quote, protection),
         :ok <- affordable(amount_in, snapshot) do
      limits = %{amount_in: amount_in, min_out: min_out, protection: protection}
      {:ok, build(trade, limits, snapshot, pool, venue)}
    end
  end

  def prepare(_request, _address, _opts), do: unavailable(:invalid_direction)

  @doc """
  Today's quote for an amount, for anyone looking at the form: what the pool
  would pay out after its fees, and the token's price in the pool's currency
  that payout implies. It reads only public pool facts and binds nothing; the
  review is what a wallet signs.
  """
  @spec estimate(map()) :: {:ok, %{received: String.t(), rate: String.t()}} | {:error, term()}
  def estimate(%{launch: launch, direction: direction, amount: amount})
      when direction in [:buy, :sell] do
    with {:ok, pool} <- pool(launch),
         {:ok, venue} <- venue(pool),
         trade <- trade(pool, direction),
         {:ok, amount_in} <- amount_in(amount, trade.sell.decimals),
         {:ok, quote} <- quote(trade, amount_in, pool.block, venue) do
      {:ok,
       %{
         received: compact(units(quote, trade.buy), 8),
         rate: rate(trade, amount_in, quote, pool)
       }}
    end
  end

  @doc """
  Fresh quotes both ways for a trade worth `amount` of the pool's currency at
  the pool's price now: what buying with that amount gets, what selling that
  much worth of the token pays, and how far each lands from the pool's price
  with the pool's and the hook's fees included. Public facts only; nothing is
  bound to it.
  """
  @spec impact(map()) :: {:ok, map()} | {:error, term()}
  def impact(%{launch: launch, amount: amount}) do
    with {:ok, pool} <- pool(launch),
         {:ok, venue} <- venue(pool),
         {:ok, price} <- pool_price(pool),
         {:ok, currency_in} <- amount_in(amount, pool.currency.decimals),
         {:ok, token_in} <- token_worth(currency_in, price, pool),
         {:ok, bought} <- quote(trade(pool, :buy), currency_in, pool.block, venue),
         {:ok, sold} <- quote(trade(pool, :sell), token_in, pool.block, venue) do
      buy_price = unit_price(currency_in, bought, pool)
      sell_price = unit_price(sold, token_in, pool)

      {:ok,
       %{
         block: pool.block.number,
         price: compact(Decimal.to_string(price, :normal), 6),
         buy: %{
           pay: units(currency_in, pool.currency),
           get: compact(units(bought, pool.token), 8),
           price: compact(Decimal.to_string(buy_price, :normal), 6),
           cost: percent(Decimal.sub(Decimal.div(buy_price, price), 1))
         },
         sell: %{
           pay: compact(units(token_in, pool.token), 8),
           get: compact(units(sold, pool.currency), 8),
           price: compact(Decimal.to_string(sell_price, :normal), 6),
           cost: percent(Decimal.sub(1, Decimal.div(sell_price, price)))
         }
       }}
    end
  end

  defp pool_price(%{current: %{price: %{value: value}}}),
    do: {:ok, Decimal.new(String.trim_trailing(value, "…"))}

  defp pool_price(_pool), do: unavailable(:chain_unavailable)

  # The token amount worth `currency_in` at the pool's price, cut to a whole
  # atomic unit.
  defp token_worth(currency_in, price, pool) do
    atomic =
      currency_in
      |> Decimal.new()
      |> Decimal.mult(Integer.pow(10, pool.token.decimals))
      |> Decimal.div(Decimal.mult(price, Integer.pow(10, pool.currency.decimals)))
      |> Decimal.round(0, :down)
      |> Decimal.to_integer()

    if atomic > 0, do: {:ok, atomic}, else: unavailable(:amount_required)
  end

  # Currency per whole token for one side of a trade, in whole units.
  defp unit_price(currency_atomic, token_atomic, pool),
    do:
      Decimal.div(
        Decimal.div(currency_atomic, Integer.pow(10, pool.currency.decimals)),
        Decimal.div(token_atomic, Integer.pow(10, pool.token.decimals))
      )

  defp percent(fraction),
    do: fraction |> Decimal.mult(100) |> Decimal.round(2) |> Decimal.to_string(:normal)

  @doc """
  What a wallet holds of the pool's two sides, for the form's balance lines.
  A public read of public balances; nothing is bound to it.
  """
  @spec balances(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def balances(launch, address) do
    with {:ok, holder} <- address(address),
         {:ok, pool} <- pool(launch),
         {:ok, venue} <- venue(pool),
         {:ok, token} <- balance(pool.token, holder, pool.block, venue.rpc),
         {:ok, currency} <- balance(pool.currency, holder, pool.block, venue.rpc),
         do: {:ok, %{token: token, currency: currency}}
  end

  defp balance(asset, holder, block, rpc) do
    with {:ok, atomic} <-
           chain(
             Rpc.call_uint(asset.address, Abi.encode_erc20("balance_of", [holder]), block, rpc)
           ),
         do:
           {:ok, %{atomic: atomic, decimals: asset.decimals, shown: held(atomic, asset.decimals)}}
  end

  # A balance line: cut, never rounded up, to four decimal places.
  defp held(atomic, decimals) do
    atomic
    |> Decimal.new()
    |> Decimal.div(Decimal.new(Integer.pow(10, decimals)))
    |> Decimal.round(4, :down)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  @doc "A whole-percent share of a balance from `balances/2`, as the exact amount to type."
  @spec portion(%{atomic: non_neg_integer(), decimals: non_neg_integer()}, 1..100) :: String.t()
  def portion(%{atomic: atomic, decimals: decimals}, percent) when percent in 1..100,
    do: Rpc.format_units(div(atomic * percent, 100), decimals)

  # The token's price in the pool's currency, whichever way the trade runs.
  defp rate(trade, amount_in, quote, pool) do
    {token_atomic, currency_atomic} =
      if trade.direction == :buy, do: {quote, amount_in}, else: {amount_in, quote}

    price =
      currency_atomic
      |> Decimal.new()
      |> Decimal.div(Decimal.new(Integer.pow(10, pool.currency.decimals)))
      |> Decimal.div(Decimal.div(token_atomic, Integer.pow(10, pool.token.decimals)))
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    "1 #{pool.token.symbol} = #{compact(price, 6)} #{pool.currency.symbol}"
  end

  # The pool and the two sides of the trade

  defp pool(%{chain: :base, auction: auction}), do: auction |> Pool.read() |> pooled()

  defp pool(%{chain: :robinhood, auction: auction}),
    do: auction |> RobinhoodPool.read() |> pooled()

  defp pool(_launch), do: unavailable(:swap_unavailable)

  defp pooled({:ok, pool}), do: {:ok, pool}
  defp pooled({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  defp pooled({:error, _reason}), do: unavailable(:swap_unavailable)

  # Where the trade runs: the deployment's RPC door, the chain its wallet
  # sends on, router, quoter and Permit2. Base venues trade through
  # Uniswap's own router; a Robinhood deployment trades only when it names a
  # router and quoter.
  defp venue(%{chain: :base, kind: :agent}), do: base_venue(Lab.current(), &LabRpc.opts/1)

  defp venue(%{chain: :base, kind: :stocks}),
    do: base_venue(StocksLab.current(), &StocksLab.rpc_opts/1)

  defp venue(%{chain: :robinhood, kind: :stocks}), do: robinhood_venue(RobinhoodLab.current())
  defp venue(_pool), do: unavailable(:swap_unavailable)

  defp base_venue({:ok, config}, rpc) do
    {:ok,
     %{
       chain: :base,
       network: Client.chain(config),
       rpc: rpc.(config),
       router: @base_router,
       quoter: @base_quoter,
       permit2: Permit2Abi.address()
     }}
  end

  defp base_venue({:error, _reason}, _rpc), do: unavailable(:swap_unavailable)

  defp robinhood_venue({:ok, config}) do
    case RobinhoodLab.swap_addresses(config) do
      {:ok, %{router: router, quoter: quoter}} ->
        {:ok,
         %{
           chain: :robinhood,
           network: Client.chain(config),
           rpc: RobinhoodLab.rpc_opts(config),
           router: router,
           quoter: quoter,
           permit2: RobinhoodLab.address!(config, :permit2)
         }}

      :error ->
        unavailable(:swap_unavailable)
    end
  end

  defp robinhood_venue({:error, _reason}), do: unavailable(:swap_unavailable)

  defp trade(pool, direction) do
    {sell, buy} =
      if direction == :buy, do: {pool.currency, pool.token}, else: {pool.token, pool.currency}

    {currency0, currency1} =
      if pool.token_is_currency0?,
        do: {pool.token.address, pool.currency.address},
        else: {pool.currency.address, pool.token.address}

    %{
      direction: direction,
      sell: sell,
      buy: buy,
      zero_for_one: Address.equal?(sell.address, currency0),
      pool_key: [currency0, currency1, pool.pool_fee, pool.tick_spacing, pool.hook]
    }
  end

  @doc """
  The price protection a trader typed, as hundredths of a percent: a plain
  number from 1 to 10, rounded to two decimal places.
  """
  @spec protection(term()) :: {:ok, 100..1_000} | {:error, term()}
  def protection(value) when is_binary(value) do
    with true <- Regex.match?(~r/\A[0-9]{1,2}(\.[0-9]{0,18})?\z/, value),
         hundredths <-
           value |> Decimal.new() |> Decimal.mult(100) |> Decimal.round(0, :half_up),
         bps when bps in @protection_range <- Decimal.to_integer(hundredths) do
      {:ok, bps}
    else
      _invalid -> unavailable(:protection_out_of_range)
    end
  end

  def protection(_value), do: unavailable(:protection_out_of_range)

  @doc "Hundredths of a percent as the percent a person reads: 156 is \"1.56\"."
  def protection_percent(bps) when bps in @protection_range,
    do:
      bps
      |> Decimal.new()
      |> Decimal.div(100)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

  defp amount_in(value, decimals) when is_binary(value) do
    case Amounts.parse_units(value, decimals) do
      {:ok, amount} when amount in 1..@max_input -> {:ok, amount}
      {:ok, 0} -> unavailable(:amount_required)
      {:ok, _too_large} -> unavailable(:amount_too_large)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp amount_in(_value, _decimals), do: unavailable(:amount_required)

  # Chain snapshot, every read pinned to the block the pool facts were read at.

  defp snapshot(trade, signer, amount_in, block, venue) do
    token = trade.sell.address
    rpc = venue.rpc

    with :ok <- chain(LabRpc.ensure_contract(venue.router, block, rpc)),
         :ok <- chain(LabRpc.ensure_contract(venue.quoter, block, rpc)),
         :ok <- chain(LabRpc.ensure_contract(venue.permit2, block, rpc)),
         {:ok, balance} <-
           chain(Rpc.call_uint(token, Abi.encode_erc20("balance_of", [signer]), block, rpc)),
         {:ok, token_allowance} <-
           chain(
             Rpc.call_uint(
               token,
               Abi.encode_erc20("allowance", [signer, venue.permit2]),
               block,
               rpc
             )
           ),
         {:ok, permit2_words} <-
           chain(
             Rpc.call_words(
               venue.permit2,
               Permit2Abi.encode_allowance(signer, token, venue.router),
               block,
               3,
               rpc
             )
           ),
         {:ok, permit2} <- Permit2Abi.decode_allowance(permit2_words) |> decoded(),
         {:ok, quote} <- quote(trade, amount_in, block, venue) do
      {:ok,
       %{
         balance: balance,
         token_allowance: token_allowance,
         permit2: permit2,
         quote: quote,
         block: block
       }}
    end
  end

  # The quoter simulates the swap through the pool's hook and answers by
  # reverting, so it is only ever read through `eth_call`.
  defp quote(trade, amount_in, block, venue) do
    data =
      LabAbi.encode(
        @quoter_abi,
        "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
        [[trade.pool_key, trade.zero_for_one, amount_in, "0x"]]
      )

    case Rpc.call_words(venue.quoter, data, block, 2, venue.rpc) do
      {:ok, [amount_out, _gas]} when amount_out > 0 -> {:ok, amount_out}
      {:ok, _zero} -> unavailable(:quote_unavailable)
      {:error, reason} when reason in @transient -> unavailable(:quote_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp min_out(quote, protection) do
    case quote - div(quote * protection, 10_000) do
      min when min in 1..@uint128_max -> {:ok, min}
      _out_of_range -> unavailable(:quote_unavailable)
    end
  end

  defp affordable(amount_in, %{balance: balance}) when balance < amount_in,
    do: unavailable(:amount_above_balance)

  defp affordable(_amount_in, _snapshot), do: :ok

  # The review

  defp build(trade, limits, snapshot, pool, venue) do
    %{amount_in: amount_in, min_out: min_out} = limits
    deadline = System.os_time(:second) + @deadline_seconds

    %{
      chain: venue.network,
      steps: reviewed_steps(trade, amount_in, min_out, deadline, snapshot, venue),
      facts: review(trade, limits, snapshot, pool),
      context: %{
        direction: trade.direction,
        buy: trade.buy.address,
        buy_symbol: trade.buy.symbol,
        buy_decimals: trade.buy.decimals,
        sell_symbol: trade.sell.symbol,
        sell_decimals: trade.sell.decimals,
        amount_in: amount_in
      }
    }
  end

  # The few figures the form shows beside the wallet steps.
  defp review(
         trade,
         %{amount_in: amount_in, min_out: min_out, protection: protection},
         snapshot,
         pool
       ) do
    %{
      pay: units(amount_in, trade.sell),
      sell_symbol: trade.sell.symbol,
      receive: compact(units(snapshot.quote, trade.buy), 8),
      minimum: compact(units(min_out, trade.buy), 8),
      buy_symbol: trade.buy.symbol,
      protection: protection_percent(protection),
      fees: fees(pool, trade)
    }
  end

  # The fees already inside the quote, one line each. A Memestake pool's come
  # from its fee schedule; a Revstake pool names the pool fee it read.
  defp fees(%{kind: :stocks, chain: chain, version: version, currency: stock}, trade) do
    Enum.map(FeeSchedule.lanes(chain, version), fn
      %{charged_on: :paid} = lane ->
        "#{lane.label}: #{lane.rate} of the #{trade.sell.symbol} you pay"

      %{charged_on: :stock} = lane ->
        "#{lane.label}: #{lane.rate} of the #{stock.symbol} side"
    end)
  end

  defp fees(%{kind: :agent, lp_fee: lp_fee}, _trade),
    do: ["Trading fees, including the #{lp_fee} pool fee"]

  # The reviewed sequence: the exact allowances the router still lacks, then the
  # one swap they enable.
  defp reviewed_steps(trade, amount_in, min_out, deadline, snapshot, venue) do
    token_approval(trade, amount_in, snapshot, venue) ++
      permit2_approval(trade, amount_in, deadline, snapshot, venue) ++
      [Review.step("swap", venue.router, swap_data(venue, trade, amount_in, min_out, deadline))]
  end

  defp token_approval(_trade, amount, %{token_allowance: allowance}, _venue)
       when allowance >= amount,
       do: []

  defp token_approval(trade, amount, _snapshot, venue) do
    data = Abi.encode_erc20("approve", [venue.permit2, amount])
    [Review.step("token_approval", trade.sell.address, data)]
  end

  # A standing Permit2 allowance is reused only if it outlives the deadline.
  defp permit2_approval(
         _trade,
         amount,
         deadline,
         %{permit2: %{amount: allowed, expiration: until}},
         _venue
       )
       when allowed >= amount and until >= deadline,
       do: []

  defp permit2_approval(trade, amount, _deadline, _snapshot, venue) do
    until = System.os_time(:second) + @permit2_seconds
    data = Permit2Abi.encode_approve(trade.sell.address, venue.router, amount, until)
    [Review.step("permit2_approval", venue.permit2, data)]
  end

  defp swap_data(venue, trade, amount_in, min_out, deadline) do
    swap = swap_params(venue.chain, trade, amount_in, min_out)

    settle = LabAbi.encode_values(@currency_amount, [trade.sell.address, amount_in])
    take = LabAbi.encode_values(@currency_amount, [trade.buy.address, min_out])

    v4_swap =
      LabAbi.encode_values(
        [%{"type" => "bytes"}, %{"type" => "bytes[]"}],
        [@v4_actions, [swap, settle, take]]
      )

    LabAbi.encode(@router_abi, "execute(bytes,bytes[],uint256)", [@commands, [v4_swap], deadline])
  end

  defp swap_params(:base, trade, amount_in, min_out),
    do:
      LabAbi.encode_values([@base_swap_params], [
        [trade.pool_key, trade.zero_for_one, amount_in, min_out, "0x"]
      ])

  defp swap_params(:robinhood, trade, amount_in, min_out),
    do:
      LabAbi.encode_values([@robinhood_swap_params], [
        [trade.pool_key, trade.zero_for_one, amount_in, min_out, 0, "0x"]
      ])

  @doc """
  What a confirmed swap paid and received, read from its receipt's logs for
  `signer`, the review's own; `context` is the prepared trade's.
  """
  @spec result(map(), String.t(), [map()]) :: map()
  def result(context, signer, logs) do
    received = received(logs, context.buy, signer)

    %{
      "received_atomic" => Integer.to_string(received),
      "received_units" => compact(Rpc.format_units(received, context.buy_decimals), 8),
      "paid_units" => Rpc.format_units(context.amount_in, context.sell_decimals),
      "sell_symbol" => context.sell_symbol,
      "buy_symbol" => context.buy_symbol
    }
  end

  # What the bought token's own transfer records moved into the wallet.
  defp received(logs, token, signer) do
    to = topic_address(signer)

    logs
    |> Enum.filter(fn log ->
      Address.equal?(log["address"], token) and
        match?([@transfer_topic, _from, ^to], downcased(log["topics"]))
    end)
    |> Enum.reduce(0, fn %{"data" => "0x" <> hex}, total -> total + String.to_integer(hex, 16) end)
  end

  defp downcased(topics) when is_list(topics), do: Enum.map(topics, &String.downcase/1)
  defp downcased(_topics), do: []

  defp topic_address("0x" <> hex), do: "0x" <> String.pad_leading(String.downcase(hex), 64, "0")

  defp units(amount, %{decimals: decimals}), do: Rpc.format_units(amount, decimals)
  defp compact(value, significant), do: Amounts.compact_decimal(value, significant)

  defp decoded({:ok, value}), do: {:ok, value}
  defp decoded(:error), do: unavailable(:invalid_chain_response)

  defp chain(:ok), do: :ok
  defp chain({:ok, value}), do: {:ok, value}
  defp chain({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  defp chain({:error, reason}), do: unavailable(reason)

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        unavailable(:session_lease_required)
    end
  end

  # The page's active wallet has to be one the leased account links, read now:
  # never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: linked_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp linked_wallet(%{wallet_addresses: wallets}, candidate) when is_list(wallets) do
    if Enum.any?(wallets, &Address.equal?(&1, candidate)),
      do: {:ok, candidate},
      else: unavailable(:wrong_signer)
  end

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
