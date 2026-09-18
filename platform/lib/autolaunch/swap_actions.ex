defmodule Autolaunch.SwapActions do
  @moduledoc """
  The one boundary between a trader's wallet and a graduated token's pool.

  Preparation reads the pool's own facts and returns the whole reviewed
  sequence as a single immutable envelope: at most the exact token allowance to
  Permit2, the exact Permit2 allowance to Uniswap's router, then the one
  exact-input swap they enable. Nothing is written anywhere. The chain is the
  only record of a trade: confirmation reads the canonical receipt.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time: the wallet the page presents must
  be exactly that wallet, never another linked address.

  The quote comes from Uniswap's quoter through the pool's own hook, so it is
  already net of the pool's fees; nothing is subtracted from it a second time.
  The lowest amount the trade accepts and the deadline are exact limits the
  wallet signs; only today's quote is an estimate.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Permit2Abi, Rpc}
  alias Autolaunch.{Lab, LabAbi, LabRpc, Pool}
  alias Autolaunch.Stocks.{Amounts, LaunchOperations}
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @resource "autolaunch_swap"
  @action "autolaunch_swap"
  @contract_name "UniversalRouter"
  # Uniswap's own Base deployments; the local Base fork carries the same code.
  @router "0x6ff5693b99212da76ad316178a184ab56d299b43"
  @quoter "0x0d5e0f971ed27fbff6c2837bf31316121532048d"
  # V4_SWAP, then SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL.
  @commands "0x10"
  @v4_actions "0x060c0f"
  # Price protection: how far below today's quote the trade may settle, in
  # hundredths of a percent. The trader chooses between 1% and 10%.
  @protection_range 100..1_000
  @deadline_seconds 900
  # The quoter negates the amount as an int128, so an input stays below 2^127.
  @max_input Integer.pow(2, 127) - 1
  @uint128_max Integer.pow(2, 128) - 1
  @max_header_seconds 253_402_300_799 - @deadline_seconds
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
  @swap_params %{
    "type" => "tuple",
    "components" => [
      @pool_key,
      %{"name" => "zeroForOne", "type" => "bool"},
      %{"name" => "amountIn", "type" => "uint128"},
      %{"name" => "amountOutMinimum", "type" => "uint128"},
      %{"name" => "hookData", "type" => "bytes"}
    ]
  }
  @currency_amount [%{"type" => "address"}, %{"type" => "uint256"}]
  @steps [:token_approval, :permit2_approval, :swap]

  @doc """
  Reviews one exact-input trade on a graduated auction's pool for the signed-in
  wallet. `:buy` spends the pool's currency for the token; `:sell` the reverse.
  `protection` is the price protection in percent, from 1 to 10, rounded to two
  decimal places.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(
        %{auction: auction, direction: direction, amount: amount, protection: protection},
        address,
        opts
      )
      when direction in [:buy, :sell] do
    with {:ok, protection} <- protection(protection),
         {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, pool} <- pool(auction),
         {:ok, venue} <- venue(pool.kind),
         trade <- trade(pool, direction),
         {:ok, amount_in} <- amount_in(amount, trade.sell.decimals),
         {:ok, snapshot} <- snapshot(trade, signer, amount_in, pool.block, venue.rpc),
         {:ok, min_out} <- min_out(snapshot.quote, protection),
         :ok <- affordable(amount_in, snapshot) do
      limits = %{amount_in: amount_in, min_out: min_out, protection: protection}
      {:ok, build(trade, signer, limits, snapshot, pool, venue)}
    end
  end

  def prepare(_request, _address, _opts), do: unavailable(:invalid_direction)

  @doc """
  Today's quote for an amount, for anyone looking at the form: what the pool
  would pay out after its fees. It reads only public pool facts and binds
  nothing; the review is what a wallet signs.
  """
  @spec estimate(map()) :: {:ok, String.t()} | {:error, term()}
  def estimate(%{auction: auction, direction: direction, amount: amount})
      when direction in [:buy, :sell] do
    with {:ok, pool} <- pool(auction),
         {:ok, venue} <- venue(pool.kind),
         trade <- trade(pool, direction),
         {:ok, amount_in} <- amount_in(amount, trade.sell.decimals),
         {:ok, quote} <- quote(trade, amount_in, pool.block, venue.rpc),
         do: {:ok, compact(units(quote, trade.buy))}
  end

  @doc """
  Reads one sent step back from the chain for the signed-in wallet: `:pending`,
  `:reverted`, or `:confirmed`. A confirmed swap states what the wallet received.
  """
  @spec verify(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(envelope, step, hash, opts) when is_map(envelope) and step in @steps do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(envelope["expected_signer"], actor, opts),
         {:ok, hash} <- canonical_hash(hash),
         true <- valid_envelope?(envelope) || unavailable(:envelope_invalid),
         {:ok, venue} <- venue(envelope["arguments"]["kind"]),
         true <- venue.binding == envelope["metadata"]["lab"] || unavailable(:lab_config_changed),
         %{} = sent <- reviewed_step(envelope, step) || unavailable(:unknown_step),
         {:ok, block} <- chain(Rpc.latest_block(venue.rpc)),
         {:ok, evidence} <-
           chain(
             Rpc.canonical_outcome_evidence(
               hash,
               signer,
               sent["to"],
               sent["data"],
               block,
               venue.rpc
             )
           ),
         do: {:ok, outcome(evidence.outcome, envelope, step, signer)}
  end

  def verify(_envelope, _step, _hash, _opts), do: unavailable(:unknown_step)

  # The pool and the two sides of the trade

  defp pool(auction) do
    case Pool.read(auction) do
      {:ok, pool} -> {:ok, pool}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, _reason} -> unavailable(:swap_unavailable)
    end
  end

  defp venue(kind) when kind in [:agent, "agent"], do: venue(Lab, Lab.current(), &LabRpc.opts/1)

  defp venue(kind) when kind in [:stocks, "stocks"],
    do: venue(StocksLab, StocksLab.current(), &StocksLab.rpc_opts/1)

  defp venue(_kind), do: unavailable(:swap_unavailable)

  defp venue(lab, {:ok, config}, rpc) do
    {:ok,
     %{chain_id: lab.chain_id(), rpc: rpc.(config), binding: lab.binding(config, [:pool_manager])}}
  end

  defp venue(_lab, {:error, _reason}, _rpc), do: unavailable(:swap_unavailable)

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

  defp snapshot(trade, signer, amount_in, block, rpc) do
    token = trade.sell.address

    with :ok <- chain(LabRpc.ensure_contract(@router, block, rpc)),
         :ok <- chain(LabRpc.ensure_contract(@quoter, block, rpc)),
         {:ok, balance} <-
           chain(Rpc.call_uint(token, Abi.encode_erc20("balance_of", [signer]), block, rpc)),
         {:ok, token_allowance} <-
           chain(
             Rpc.call_uint(
               token,
               Abi.encode_erc20("allowance", [signer, Permit2Abi.address()]),
               block,
               rpc
             )
           ),
         {:ok, permit2_words} <-
           chain(
             Rpc.call_words(
               Permit2Abi.address(),
               Permit2Abi.encode_allowance(signer, token, @router),
               block,
               3,
               rpc
             )
           ),
         {:ok, permit2} <- Permit2Abi.decode_allowance(permit2_words) |> decoded(),
         {:ok, header} <- block_header(block, rpc),
         {:ok, quote} <- quote(trade, amount_in, block, rpc) do
      {:ok,
       %{
         balance: balance,
         token_allowance: token_allowance,
         permit2: permit2,
         quote: quote,
         block: block,
         timestamp: header.timestamp
       }}
    end
  end

  # The quoter simulates the swap through the pool's hook and answers by
  # reverting, so it is only ever read through `eth_call`.
  defp quote(trade, amount_in, block, rpc) do
    data =
      LabAbi.encode(
        @quoter_abi,
        "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
        [[trade.pool_key, trade.zero_for_one, amount_in, "0x"]]
      )

    case Rpc.call_words(@quoter, data, block, 2, rpc) do
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

  defp build(trade, signer, limits, snapshot, pool, venue) do
    %{amount_in: amount_in, min_out: min_out, protection: protection} = limits
    deadline = snapshot.timestamp + @deadline_seconds
    steps = reviewed_steps(trade, amount_in, min_out, deadline, snapshot)
    data = steps |> List.last() |> Map.fetch!("data")

    envelope =
      @action
      |> Envelope.new(signer, data,
        to: @router,
        resource: @resource,
        contract_name: @contract_name,
        chain_id: venue.chain_id,
        lab_binding: venue.binding,
        risk_copy: risk_copy(trade, amount_in),
        arguments: %{
          "kind" => Atom.to_string(pool.kind),
          "direction" => Atom.to_string(trade.direction),
          "pool_id" => pool.pool_id,
          "pool_manager" => pool.pool_manager,
          "hook" => pool.hook,
          "router" => @router,
          "quoter" => @quoter,
          "sell" => trade.sell.address,
          "sell_symbol" => trade.sell.symbol,
          "sell_decimals" => trade.sell.decimals,
          "buy" => trade.buy.address,
          "buy_symbol" => trade.buy.symbol,
          "buy_decimals" => trade.buy.decimals,
          "amount_in_atomic" => Integer.to_string(amount_in),
          "quote_atomic" => Integer.to_string(snapshot.quote),
          "min_out_atomic" => Integer.to_string(min_out),
          "protection_bps" => protection,
          "deadline" => Integer.to_string(deadline),
          "block_number" => snapshot.block.number,
          "block_hash" => snapshot.block.hash,
          "steps" => steps
        }
      )
      |> stored()

    %{envelope: envelope, steps: steps, review: review(trade, limits, snapshot)}
  end

  defp review(trade, %{amount_in: amount_in, min_out: min_out, protection: protection}, snapshot) do
    [
      ["You pay", "#{units(amount_in, trade.sell)} #{trade.sell.symbol}"],
      [
        "You receive about",
        "#{compact(units(snapshot.quote, trade.buy))} #{trade.buy.symbol}, after the pool's fees"
      ],
      [
        "Lowest #{trade.buy.symbol} you accept",
        "#{compact(units(min_out, trade.buy))} #{trade.buy.symbol}, at most #{protection_percent(protection)}% below today's quote"
      ],
      [
        "Must be included by",
        "#{block_time(snapshot.timestamp + @deadline_seconds)}, about #{div(@deadline_seconds, 60)} minutes after this review"
      ]
    ]
  end

  defp risk_copy(trade, amount_in) do
    "Your wallet trades #{units(amount_in, trade.sell)} #{trade.sell.symbol} for #{trade.buy.symbol} on the local Base fork with test assets and no mainnet value. The trade goes through only if you receive at least the lowest amount shown."
  end

  # The reviewed sequence: the exact allowances the router still lacks, then the
  # one swap they enable.
  defp reviewed_steps(trade, amount_in, min_out, deadline, snapshot) do
    token_approval(trade, amount_in, snapshot) ++
      permit2_approval(trade, amount_in, deadline, snapshot) ++
      [
        %{
          "step" => "swap",
          "to" => @router,
          "data" => swap_data(trade, amount_in, min_out, deadline)
        }
      ]
  end

  defp token_approval(_trade, amount, %{token_allowance: allowance}) when allowance >= amount,
    do: []

  defp token_approval(trade, amount, _snapshot) do
    [
      %{
        "step" => "token_approval",
        "to" => trade.sell.address,
        "data" => Abi.encode_erc20("approve", [Permit2Abi.address(), amount]),
        "amount" => Integer.to_string(amount)
      }
    ]
  end

  # A standing Permit2 allowance is reused only if it outlives the deadline.
  defp permit2_approval(_trade, amount, deadline, %{
         permit2: %{amount: allowed, expiration: until}
       })
       when allowed >= amount and until >= deadline,
       do: []

  defp permit2_approval(trade, amount, deadline, _snapshot) do
    [
      %{
        "step" => "permit2_approval",
        "to" => Permit2Abi.address(),
        "data" => Permit2Abi.encode_approve(trade.sell.address, @router, amount, deadline),
        "amount" => Integer.to_string(amount),
        "expiration" => Integer.to_string(deadline)
      }
    ]
  end

  defp swap_data(trade, amount_in, min_out, deadline) do
    swap =
      LabAbi.encode_values([@swap_params], [
        [trade.pool_key, trade.zero_for_one, amount_in, min_out, "0x"]
      ])

    settle = LabAbi.encode_values(@currency_amount, [trade.sell.address, amount_in])
    take = LabAbi.encode_values(@currency_amount, [trade.buy.address, min_out])

    v4_swap =
      LabAbi.encode_values(
        [%{"type" => "bytes"}, %{"type" => "bytes[]"}],
        [@v4_actions, [swap, settle, take]]
      )

    LabAbi.encode(@router_abi, "execute(bytes,bytes[],uint256)", [@commands, [v4_swap], deadline])
  end

  # Confirmation

  defp valid_envelope?(envelope) do
    Envelope.valid_for_confirmation?(envelope,
      resource: @resource,
      action: @action,
      signer: envelope["expected_signer"],
      to: @router,
      contract_name: @contract_name
    )
  end

  defp reviewed_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  defp outcome(:pending, _envelope, _step, _signer), do: %{outcome: :pending}
  defp outcome(:reverted, _envelope, _step, _signer), do: %{outcome: :reverted}

  defp outcome({:success, logs}, envelope, :swap, signer) do
    arguments = envelope["arguments"]
    received = received(logs, arguments["buy"], signer)

    %{
      outcome: :confirmed,
      result: %{
        "received_atomic" => Integer.to_string(received),
        "received_units" => Rpc.format_units(received, arguments["buy_decimals"]),
        "buy_symbol" => arguments["buy_symbol"]
      }
    }
  end

  defp outcome({:success, _logs}, _envelope, _approval, _signer), do: %{outcome: :confirmed}

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

  # The header of the snapshot block itself, by hash, so the deadline is
  # counted from the same block every read above was pinned to.
  defp block_header(%{hash: hash}, rpc) do
    with {:ok, %{"hash" => header_hash, "timestamp" => "0x" <> hex}}
         when is_binary(header_hash) and is_binary(hex) <-
           Rpc.request("eth_getBlockByHash", [hash, false], rpc),
         true <- String.downcase(header_hash) == hash,
         true <- Regex.match?(~r/^[0-9a-f]+$/i, hex),
         {timestamp, ""} when timestamp in 0..@max_header_seconds <- Integer.parse(hex, 16) do
      {:ok, %{timestamp: timestamp}}
    else
      {:error, reason} -> chain({:error, reason})
      _other -> unavailable(:invalid_chain_response)
    end
  end

  defp units(amount, %{decimals: decimals}), do: Rpc.format_units(amount, decimals)
  defp compact(value), do: Amounts.compact_decimal(value)

  defp block_time(unix),
    do: unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

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

  # The wallet the page presents has to be the signed-in wallet of the leased
  # account, read now: not another linked address, and never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: signed_in_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp signed_in_wallet(%{wallet_address: wallet}, candidate) when is_binary(wallet) do
    if Address.equal?(wallet, candidate), do: {:ok, candidate}, else: unavailable(:wrong_signer)
  end

  defp signed_in_wallet(_account, _candidate), do: unavailable(:wrong_signer)

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp address(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
