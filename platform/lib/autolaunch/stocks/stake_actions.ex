defmodule Autolaunch.Stocks.StakeActions do
  @moduledoc """
  The one boundary between a wallet and a graduated launch's staking contract:
  a Revstake launch's revenue splitter with its LP locker on Base, or a
  memestock launch's memestake splitter with its fee hook and LP locker, on
  Base or on Robinhood.

  Six reviewed actions, each one immutable envelope the wallet signs step by
  step: stake (the exact token allowance to the splitter when it is short, then
  the stake), unstake, claim (every reward the splitter holds for the wallet),
  settle (the hook's staker lane into the splitter, open to anyone), collect
  (the locked positions' trading fees into the splitter, open to anyone) and
  convert (a memestock hook's REGENT lane sold through the stock's route into
  REGENT's revenue, only by the wallet the Safe named as the hook's executor).
  A Revstake splitter's hook lane is pulled on the trade itself, so it offers
  no settle and no convert. Nothing is written anywhere: the chain is the only
  record, and confirmation reads the canonical receipt.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time: the wallet the page presents must
  be exactly that wallet, never another linked address.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{Lab, LabAbi, Pool}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.{Amounts, LaunchOperations}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @resource "autolaunch_stake"
  @kinds [:stake, :unstake, :claim, :settle, :collect, :convert]
  @actions %{
    stake: "autolaunch_stake",
    unstake: "autolaunch_unstake",
    claim: "autolaunch_claim",
    settle: "autolaunch_settle_stakers",
    collect: "autolaunch_collect_fees",
    convert: "autolaunch_convert_regent_share"
  }
  @steps [
    :token_approval,
    :stake,
    :unstake,
    :claim,
    :settle,
    :collect_full_range,
    :collect_stock_only,
    :convert
  ]
  # Where a launch lives, by its chain and kind: its deployment and that
  # deployment's event signatures, the configuration keys of the contracts a
  # review binds to, the locker, the actions the staking contract offers and
  # what each one signs against. A memestock venue also names its launchpad
  # and stock route, the hook call that converts REGENT's lane and the event
  # that records it.
  @venues %{
    {:base, :agent} => %{
      lab: Lab,
      abi: LabAbi,
      binding: [:strategy, :hook, :lp_locker],
      hook: :hook,
      locker: :lp_locker,
      kinds: [:stake, :unstake, :claim, :collect],
      contracts: %{
        stake: "SubjectSplitterV1",
        unstake: "SubjectSplitterV1",
        claim: "SubjectSplitterV1",
        collect: "RevstakeLPLocker"
      }
    },
    {:base, :stocks} => %{
      lab: StocksLab,
      abi: StocksLabAbi,
      binding: [:launchpad, :hook, :locker],
      hook: :hook,
      locker: :locker,
      launchpad: :launchpad,
      route: :route,
      convert: "settleRegentLane(bytes32,uint256,uint256)",
      converted: "RegentLaneSettled(bytes32,uint256,uint256)",
      kinds: @kinds,
      contracts: %{
        stake: "MemestockSplitterV1",
        unstake: "MemestockSplitterV1",
        claim: "MemestockSplitterV1",
        settle: "StocksFeeHookV1",
        collect: "MemestockLPLocker",
        convert: "StocksFeeHookV1"
      }
    },
    {:robinhood, :stocks} => %{
      lab: RobinhoodLab,
      abi: RobinhoodLabAbi,
      binding: [:stocks_launchpad, :stocks_hook, :stocks_locker],
      hook: :stocks_hook,
      locker: :stocks_locker,
      launchpad: :stocks_launchpad,
      route: :stock_route,
      convert: "settleProtocolLane(bytes32,uint256,uint256)",
      converted: "ProtocolLaneSettled(bytes32,uint256,uint256)",
      kinds: @kinds,
      contracts: %{
        stake: "MemestockSplitterV1",
        unstake: "MemestockSplitterV1",
        claim: "MemestockSplitterV1",
        settle: "RobinhoodFeeHookV1",
        collect: "MemestockLPLocker",
        convert: "RobinhoodFeeHookV1"
      }
    }
  }
  @token_decimals 18
  # Both stock routes refuse a sale more than 5% under the Chainlink quote, so
  # a conversion never asks for less than that.
  @route_floor_bps 9_500
  @bps 10_000
  @uint128_max Integer.pow(2, 128) - 1
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  def kinds, do: @kinds

  @doc """
  What one wallet has in a launch's splitter, read at the block the pool facts
  were read at: its token balance, its stake, its allowance to the splitter and
  what it can claim in each of the three assets (the dollar, the launch's token
  and the currency it trades against). A public read of public figures;
  nothing is bound to it.
  """
  @spec position(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def position(pool, address) do
    splitter = pool.fees.splitter.address
    dollar = pool.fees.splitter.dollar
    venue = venue(pool)

    with {:ok, holder} <- address(address),
         {:ok, config} <- lab(venue),
         rpc <- venue.lab.rpc_opts(config),
         abi <- venue.lab.abi!(config, :splitter),
         {:ok, balance} <- erc20(pool.token.address, "balance_of", [holder], pool.block, rpc),
         {:ok, allowance} <-
           erc20(pool.token.address, "allowance", [holder, splitter], pool.block, rpc),
         {:ok, staked} <-
           splitter_uint(splitter, abi, "stakedOf(address)", [holder], pool.block, rpc),
         {:ok, dollar_owed} <- claimable(splitter, abi, dollar.address, holder, pool, rpc),
         {:ok, token} <- claimable(splitter, abi, pool.token.address, holder, pool, rpc),
         {:ok, stock} <- claimable(splitter, abi, pool.currency.address, holder, pool, rpc) do
      {:ok,
       %{
         balance: amount(balance, @token_decimals),
         staked: amount(staked, @token_decimals),
         allowance: allowance,
         claimable: %{
           dollar: amount(dollar_owed, dollar.decimals),
           token: amount(token, @token_decimals),
           stock: amount(stock, pool.currency.decimals)
         }
       }}
    end
  end

  @doc """
  Reviews one action on a graduated launch's splitter for the signed-in
  wallet. The launch is `%{chain: :base, auction: auction_record}` or
  `%{chain: :robinhood, auction: auction_address}`. `:stake` and `:unstake`
  take the token amount typed and `:convert` the stock amount; the other three
  take nothing.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{kind: kind, launch: launch} = request, address, opts) when kind in @kinds do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, pool} <- pool(launch),
         true <- kind in venue(pool).kinds || unavailable(:unknown_action),
         :ok <- converter(kind, pool, signer),
         {:ok, config} <- lab(venue(pool)),
         {:ok, wallet} <- position(pool, signer),
         {:ok, amount} <- amount(kind, Map.get(request, :amount), wallet),
         {:ok, amount} <- conversion(kind, amount, pool, config),
         do: {:ok, build(kind, pool, config, signer, wallet, amount)}
  end

  def prepare(_request, _address, _opts), do: unavailable(:unknown_action)

  @doc "A whole-percent share of an amount from `position/2`, as the exact amount to type."
  @spec portion(%{atomic: non_neg_integer(), decimals: non_neg_integer()}, 1..100) :: String.t()
  def portion(%{atomic: atomic, decimals: decimals}, percent) when percent in 1..100,
    do: Rpc.format_units(div(atomic * percent, 100), decimals)

  @doc """
  Reads one sent step back from the chain for the signed-in wallet: `:pending`,
  `:reverted`, or `:confirmed` with what the chain says moved.
  """
  @spec verify(map(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(envelope, step, hash, opts) when is_map(envelope) and step in @steps do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(envelope["expected_signer"], actor, opts),
         {:ok, hash} <- canonical_hash(hash),
         true <- valid_envelope?(envelope) || unavailable(:envelope_invalid),
         {:ok, venue} <- envelope_venue(envelope),
         {:ok, config} <- lab(venue),
         true <-
           binding(venue, config) == envelope["metadata"]["lab"] ||
             unavailable(:lab_config_changed),
         %{} = sent <- reviewed_step(envelope, step) || unavailable(:unknown_step),
         rpc <- venue.lab.rpc_opts(config),
         {:ok, block} <- chain(Rpc.latest_block(rpc)),
         {:ok, evidence} <-
           chain(
             Rpc.canonical_outcome_evidence(hash, signer, sent["to"], sent["data"], block, rpc)
           ),
         do: {:ok, outcome(evidence.outcome, envelope, step)}
  end

  def verify(_envelope, _step, _hash, _opts), do: unavailable(:unknown_step)

  # Wallet reads

  defp erc20(token, function, arguments, block, rpc),
    do: chain(Rpc.call_uint(token, Abi.encode_erc20(function, arguments), block, rpc))

  defp splitter_uint(splitter, abi, signature, arguments, block, rpc),
    do: chain(Rpc.call_uint(splitter, LabAbi.encode(abi, signature, arguments), block, rpc))

  defp claimable(splitter, abi, token, holder, pool, rpc),
    do:
      splitter_uint(splitter, abi, "claimable(address,address)", [token, holder], pool.block, rpc)

  defp amount(atomic, decimals),
    do: %{atomic: atomic, decimals: decimals, shown: Rpc.format_units(atomic, decimals)}

  # The amount an action moves, refused before any review exists when the
  # splitter would refuse it too.
  defp amount(:stake, value, wallet) do
    with {:ok, amount} <- parsed(value),
         true <- amount <= wallet.balance.atomic || unavailable(:amount_above_balance),
         do: {:ok, amount}
  end

  defp amount(:unstake, value, wallet) do
    with {:ok, amount} <- parsed(value),
         true <- amount <= wallet.staked.atomic || unavailable(:amount_above_stake),
         do: {:ok, amount}
  end

  defp amount(:convert, value, _wallet), do: {:ok, value}

  defp amount(_kind, _value, _wallet), do: {:ok, nil}

  defp parsed(value, decimals \\ @token_decimals)

  defp parsed(value, decimals) when is_binary(value) do
    case Amounts.parse_units(value, decimals) do
      {:ok, amount} when amount in 1..@uint128_max -> {:ok, amount}
      {:ok, 0} -> unavailable(:amount_required)
      {:ok, _too_large} -> unavailable(:amount_too_large)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp parsed(_value, _decimals), do: unavailable(:amount_required)

  # Only the wallet the Safe named as the hook's executor may convert, and the
  # hook refuses anyone else, so nobody else is offered the review.
  defp converter(:convert, pool, signer) do
    if Address.equal?(pool.fees.regent.converter, signer),
      do: :ok,
      else: unavailable(:not_converter)
  end

  defp converter(_kind, _pool, _signer), do: :ok

  # The stock amount to sell from REGENT's lane, what the stock's route says it
  # is worth at the Chainlink price right now, and the least the sale may
  # bring. The hook reads the stock's route from the launchpad when it sells,
  # so the quote comes from that same route.
  defp conversion(:convert, value, pool, config) do
    venue = venue(pool)
    rpc = venue.lab.rpc_opts(config)

    with {:ok, stock} <- parsed(value, pool.currency.decimals),
         true <- stock <= pool.fees.regent.accrued_atomic || unavailable(:amount_above_share),
         {:ok, route} <- route(venue, config, pool, rpc),
         {:ok, worth} <- quote(venue, config, route, pool, stock, rpc) do
      {:ok, %{stock: stock, worth: worth, least: div(worth * @route_floor_bps, @bps)}}
    end
  end

  defp conversion(_kind, amount, _pool, _config), do: {:ok, amount}

  defp route(venue, config, pool, rpc) do
    launchpad = venue.lab.address!(config, venue.launchpad)
    abi = venue.lab.abi!(config, venue.launchpad)
    data = LabAbi.encode(abi, "stockAdmission(address)", [pool.currency.address])

    with {:ok, [_admitted, _kind, route]} <-
           chain(Rpc.call_words(launchpad, data, pool.block, 3, rpc)) do
      case Abi.word_address(route) do
        {:ok, route} -> {:ok, route}
        :error -> unavailable(:no_route)
      end
    end
  end

  # The route refuses to quote while its Chainlink feed is stopped or stale,
  # and then it would refuse the sale too.
  defp quote(venue, config, route, pool, stock, rpc) do
    data =
      LabAbi.encode(
        venue.lab.abi!(config, venue.route),
        "quoteExactIn(address,address,uint256)",
        [
          pool.currency.address,
          pool.fees.splitter.dollar.address,
          stock
        ]
      )

    case Rpc.call_uint(route, data, pool.block, rpc) do
      {:ok, worth} -> {:ok, worth}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, _reason} -> unavailable(:price_unavailable)
    end
  end

  # The pool and its venue

  defp pool(%{chain: :base, auction: auction}), do: auction |> Pool.read() |> pooled()

  defp pool(%{chain: :robinhood, auction: auction}),
    do: auction |> RobinhoodPool.read() |> pooled()

  defp pooled({:ok, pool}), do: {:ok, pool}
  defp pooled({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  defp pooled({:error, _reason}), do: unavailable(:stake_unavailable)

  defp venue(%{chain: chain, kind: kind}), do: Map.fetch!(@venues, {chain, kind})

  # The venue a signed envelope was reviewed on, named in its own arguments.
  defp envelope_venue(%{"arguments" => %{"chain" => chain, "launch" => launch}})
       when chain in ["base", "robinhood"] and launch in ["agent", "stocks"],
       do:
         {:ok,
          Map.fetch!(@venues, {String.to_existing_atom(chain), String.to_existing_atom(launch)})}

  defp envelope_venue(_envelope), do: unavailable(:envelope_invalid)

  defp lab(venue) do
    case venue.lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:stake_unavailable)
    end
  end

  defp binding(venue, config), do: venue.lab.binding(config, venue.binding)

  defp locker(venue, config), do: venue.lab.address!(config, venue.locker)

  # The review

  defp build(kind, pool, config, signer, wallet, amount) do
    venue = venue(pool)
    steps = reviewed_steps(kind, pool, venue, config, wallet, amount)
    last = List.last(steps)

    envelope =
      @actions
      |> Map.fetch!(kind)
      |> Envelope.new(signer, last["data"],
        to: last["to"],
        resource: @resource,
        contract_name: Map.fetch!(venue.contracts, kind),
        chain_id: venue.lab.chain_id(),
        lab_binding: binding(venue, config),
        risk_copy: risk_copy(kind, pool, venue, amount),
        arguments: %{
          "kind" => Atom.to_string(kind),
          "chain" => Atom.to_string(pool.chain),
          "launch" => Atom.to_string(pool.kind),
          "pool_id" => pool.pool_id,
          "splitter" => pool.fees.splitter.address,
          "hook" => pool.hook,
          "locker" => locker(venue, config),
          "token" => pool.token.address,
          "token_symbol" => pool.token.symbol,
          "currency" => pool.currency.address,
          "currency_symbol" => pool.currency.symbol,
          "currency_decimals" => pool.currency.decimals,
          "dollar" => pool.fees.splitter.dollar.address,
          "dollar_symbol" => pool.fees.splitter.dollar.symbol,
          "dollar_decimals" => pool.fees.splitter.dollar.decimals,
          "amount_atomic" => amount_atomic(amount),
          "block_number" => pool.block.number,
          "block_hash" => pool.block.hash,
          "steps" => steps
        }
      )
      |> stored()

    %{kind: kind, envelope: envelope, steps: steps, review: review(kind, pool, wallet, amount)}
  end

  defp amount_atomic(nil), do: nil
  defp amount_atomic(%{stock: stock}), do: Integer.to_string(stock)
  defp amount_atomic(amount), do: Integer.to_string(amount)

  # The plain facts the panel shows beside the wallet steps.
  defp review(:stake, pool, wallet, amount) do
    [
      ["You stake", "#{units(amount, @token_decimals)} #{pool.token.symbol}"],
      [
        "Your stake after",
        "#{units(wallet.staked.atomic + amount, @token_decimals)} #{pool.token.symbol}"
      ]
    ]
  end

  defp review(:unstake, pool, wallet, amount) do
    [
      ["You unstake", "#{units(amount, @token_decimals)} #{pool.token.symbol}"],
      [
        "Your stake after",
        "#{units(wallet.staked.atomic - amount, @token_decimals)} #{pool.token.symbol}"
      ]
    ]
  end

  defp review(:claim, pool, wallet, _amount) do
    [
      [pool.fees.splitter.dollar.symbol, wallet.claimable.dollar.shown],
      [pool.token.symbol, wallet.claimable.token.shown],
      [pool.currency.symbol, wallet.claimable.stock.shown]
    ]
  end

  defp review(:settle, pool, _wallet, _amount) do
    [["Waiting for stakers", "#{pool.fees.stakers.accrued} #{pool.currency.symbol}"]]
  end

  defp review(:collect, pool, _wallet, _amount) do
    Enum.map(pool.positions, fn position ->
      [position.label <> " position", uncollected_copy(position.uncollected, pool)]
    end)
  end

  defp review(:convert, pool, _wallet, %{stock: stock, worth: worth, least: least}) do
    currency = pool.currency
    dollar = pool.fees.splitter.dollar

    [
      ["Waiting in REGENT's share", "#{pool.fees.regent.accrued} #{currency.symbol}"],
      ["You convert", "#{units(stock, currency.decimals)} #{currency.symbol}"],
      ["Worth at the Chainlink price", "#{units(worth, dollar.decimals)} #{dollar.symbol}"],
      ["Least accepted", "#{units(least, dollar.decimals)} #{dollar.symbol}"]
    ]
  end

  defp uncollected_copy(nil, _pool), do: "Not readable right now"

  defp uncollected_copy(%{token_amount: token, currency_amount: currency}, pool),
    do: "#{token} #{pool.token.symbol} · #{currency} #{pool.currency.symbol}"

  defp risk_copy(:stake, pool, venue, amount),
    do:
      "Your wallet stakes #{units(amount, @token_decimals)} #{pool.token.symbol} in this launch's staking contract on #{network(venue)}. You can unstake later; not right after staking."

  defp risk_copy(:unstake, pool, venue, amount),
    do:
      "Your wallet takes #{units(amount, @token_decimals)} #{pool.token.symbol} back out of this launch's staking contract on #{network(venue)}."

  defp risk_copy(:claim, pool, venue, _amount),
    do:
      "Your wallet claims every reward this launch's staking contract holds for it, in #{pool.fees.splitter.dollar.symbol}, #{pool.token.symbol} and #{pool.currency.symbol}, on #{network(venue)}."

  defp risk_copy(:settle, pool, venue, _amount),
    do:
      "Your wallet moves the #{pool.currency.symbol} waiting in the stakers' fee lane into this launch's staking contract, for every staker, on #{network(venue)}. Nothing comes to your wallet."

  defp risk_copy(:collect, pool, venue, _amount),
    do:
      "Your wallet collects the locked liquidity's trading fees into this launch's staking contract, for every #{pool.token.symbol} staker, on #{network(venue)}. Nothing comes to your wallet."

  defp risk_copy(:convert, pool, venue, %{stock: stock, least: least}) do
    dollar = pool.fees.splitter.dollar

    "Your wallet sells #{units(stock, pool.currency.decimals)} #{pool.currency.symbol} from REGENT's share of this launch's trading fees for at least #{units(least, dollar.decimals)} #{dollar.symbol}, and the #{dollar.symbol} goes to REGENT's revenue, on #{network(venue)}. Nothing comes to your wallet."
  end

  defp network(%{lab: RobinhoodLab}) do
    if RobinhoodLab.test_chain?(),
      do: "the local Robinhood test network with test assets and no mainnet value",
      else: "Robinhood Chain"
  end

  defp network(_base) do
    if Lab.test_chain?(),
      do: "the local Base fork with test assets and no mainnet value",
      else: "Base"
  end

  # The reviewed sequence, one calldata per step, exactly what the wallet sends.
  defp reviewed_steps(:stake, pool, venue, config, wallet, amount) do
    splitter = pool.fees.splitter.address

    approval(pool.token.address, splitter, amount, wallet.allowance) ++
      [step("stake", splitter, splitter_data(venue, config, "stake(uint256)", [amount]))]
  end

  defp reviewed_steps(:unstake, pool, venue, config, _wallet, amount),
    do: [
      step(
        "unstake",
        pool.fees.splitter.address,
        splitter_data(venue, config, "unstake(uint256)", [amount])
      )
    ]

  defp reviewed_steps(:claim, pool, venue, config, _wallet, _amount),
    do: [
      step("claim", pool.fees.splitter.address, splitter_data(venue, config, "claimAll()", []))
    ]

  defp reviewed_steps(:settle, pool, venue, config, _wallet, _amount) do
    abi = venue.lab.abi!(config, venue.hook)
    data = LabAbi.encode(abi, "settleStakerLane(bytes32)", [pool.pool_id])

    [step("settle", pool.hook, data)]
  end

  defp reviewed_steps(:collect, pool, venue, config, _wallet, _amount) do
    locker = venue.lab.address!(config, venue.locker)
    abi = venue.lab.abi!(config, venue.locker)

    Enum.map(pool.positions, fn position ->
      step(
        "collect_" <> Atom.to_string(position.key),
        locker,
        LabAbi.encode(abi, "collect(uint256)", [position.token_id])
      )
    end)
  end

  defp reviewed_steps(:convert, pool, venue, config, _wallet, %{stock: stock, least: least}) do
    abi = venue.lab.abi!(config, venue.hook)
    data = LabAbi.encode(abi, venue.convert, [pool.pool_id, stock, least])

    [step("convert", pool.hook, data)]
  end

  defp approval(_token, _spender, amount, allowance) when allowance >= amount, do: []

  defp approval(token, spender, amount, _allowance) do
    [
      %{
        "step" => "token_approval",
        "to" => token,
        "data" => Abi.encode_erc20("approve", [spender, amount]),
        "amount" => Integer.to_string(amount)
      }
    ]
  end

  defp step(name, to, data), do: %{"step" => name, "to" => to, "data" => data}

  defp splitter_data(venue, config, signature, arguments),
    do: LabAbi.encode(venue.lab.abi!(config, :splitter), signature, arguments)

  # Confirmation

  defp valid_envelope?(envelope) do
    Envelope.valid_for_confirmation?(envelope,
      resource: @resource,
      actions: Map.values(@actions),
      signer: envelope["expected_signer"]
    )
  end

  defp reviewed_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  defp outcome(:pending, _envelope, _step), do: %{outcome: :pending}
  defp outcome(:reverted, _envelope, _step), do: %{outcome: :reverted}
  defp outcome({:success, _logs}, _envelope, :token_approval), do: %{outcome: :confirmed}

  defp outcome({:success, logs}, envelope, step) do
    {:ok, venue} = envelope_venue(envelope)
    %{outcome: :confirmed, result: result(step, envelope["arguments"], venue, logs)}
  end

  defp result(step, arguments, _venue, _logs) when step in [:stake, :unstake] do
    %{
      "kind" => Atom.to_string(step),
      "amount_units" => units(String.to_integer(arguments["amount_atomic"]), @token_decimals),
      "token_symbol" => arguments["token_symbol"]
    }
  end

  # What the splitter's own claim records paid out, one entry per asset.
  defp result(:claim, arguments, venue, logs) do
    paid = emitted(logs, arguments["splitter"], venue.abi.claimed_signature())

    per_token =
      Enum.reduce(paid, %{}, fn {[_account, token], [amount]}, sums ->
        Map.update(sums, token, amount, &(&1 + amount))
      end)

    %{
      "kind" => "claim",
      "dollar_units" =>
        units(claimed(per_token, arguments["dollar"]), arguments["dollar_decimals"]),
      "token_units" => units(claimed(per_token, arguments["token"]), @token_decimals),
      "stock_units" =>
        units(claimed(per_token, arguments["currency"]), arguments["currency_decimals"]),
      "dollar_symbol" => arguments["dollar_symbol"],
      "token_symbol" => arguments["token_symbol"],
      "currency_symbol" => arguments["currency_symbol"]
    }
  end

  defp result(:settle, arguments, venue, logs) do
    [{_topics, [amount]}] =
      emitted(logs, arguments["hook"], venue.abi.staker_lane_settled_signature())

    %{
      "kind" => "settle",
      "settled_units" => units(amount, arguments["currency_decimals"]),
      "currency_symbol" => arguments["currency_symbol"]
    }
  end

  defp result(collect, arguments, venue, logs)
       when collect in [:collect_full_range, :collect_stock_only] do
    [{_topics, [currency0, _currency1, amount0, amount1]}] =
      emitted(logs, arguments["locker"], venue.abi.fees_deposited_signature())

    {:ok, currency0} = Abi.word_address(currency0)

    {token, currency} =
      if Address.equal?(currency0, arguments["token"]),
        do: {amount0, amount1},
        else: {amount1, amount0}

    %{
      "kind" => "collect",
      "token_units" => units(token, @token_decimals),
      "currency_units" => units(currency, arguments["currency_decimals"]),
      "token_symbol" => arguments["token_symbol"],
      "currency_symbol" => arguments["currency_symbol"]
    }
  end

  defp result(:convert, arguments, venue, logs) do
    [{_topics, [converted, deposited]}] = emitted(logs, arguments["hook"], venue.converted)

    %{
      "kind" => "convert",
      "converted_units" => units(converted, arguments["currency_decimals"]),
      "currency_symbol" => arguments["currency_symbol"],
      "dollar_units" => units(deposited, arguments["dollar_decimals"]),
      "dollar_symbol" => arguments["dollar_symbol"]
    }
  end

  defp claimed(per_token, address), do: Map.get(per_token, String.downcase(address), 0)

  # Every record of one event the named contract wrote into this receipt, as
  # its indexed words (addresses lowercased) and its data words.
  defp emitted(logs, emitter, signature) do
    topic = LabAbi.topic(signature)

    logs
    |> Enum.filter(fn log ->
      Address.equal?(log["address"], emitter) and
        String.downcase(hd(log["topics"])) == topic
    end)
    |> Enum.map(fn log ->
      indexed = log["topics"] |> tl() |> Enum.map(&topic_value/1)
      {indexed, data_words(log)}
    end)
  end

  defp topic_value("0x" <> hex) do
    case Abi.word_address(String.to_integer(hex, 16)) do
      {:ok, address} -> address
      :error -> "0x" <> String.downcase(hex)
    end
  end

  defp data_words(%{"data" => "0x" <> hex}),
    do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  defp units(amount, decimals), do: Rpc.format_units(amount, decimals)

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

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
