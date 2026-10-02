defmodule Autolaunch.Stocks.StakeActions do
  @moduledoc """
  The one boundary between a wallet and a graduated launch's staking contract:
  a Revstake launch's revenue splitter with its LP locker on Base, or a
  memestock launch's memestake splitter with its fee hook and LP locker, on
  Base or on Robinhood.

  Seven actions, each one review of the steps the wallet sends in turn: stake
  (the exact token allowance to the splitter when it is short, then the
  stake), unstake, claim (every reward the splitter holds for the wallet),
  settle (the hook's staker lane into the splitter, open to anyone), collect
  (the locked position's trading fees into the splitter, open to anyone),
  convert (a memestock hook's REGENT lane sold through the stock's route into
  REGENT's revenue, only by the wallet the Safe named as the hook's executor)
  and release (the vested part of a second-launchpad memestock launch's
  creator allocation, paid to its creator, open to anyone).
  A Revstake splitter's hook lane is pulled on the trade itself, so it offers
  no settle and no convert. Nothing is written anywhere: the chain is the only
  record, and the page reads what each step did from its receipt.

  Every review binds to one of the wallets of the account the session lease
  names, read inside the lease at call time: the page's active wallet must be
  one the account links, never a guess.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, Rpc}
  alias Autolaunch.{Lab, LabAbi, Pool}
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.{Amounts, LaunchOperations}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.{Address, Review}

  @kinds [:stake, :unstake, :claim, :settle, :collect, :convert, :release]
  # Where a launch lives, by its chain and kind: its deployment and that
  # deployment's event signatures and the actions the staking contract offers.
  # A memestock venue also names its stock route, the hook call that converts
  # REGENT's lane and the event that records it; its launchpad, hook and
  # locker are those of the launch's own contracts version.
  @venues %{
    {:base, :agent} => %{
      lab: Lab,
      abi: LabAbi,
      kinds: [:stake, :unstake, :claim, :collect]
    },
    {:base, :stocks} => %{
      lab: StocksLab,
      abi: StocksLabAbi,
      route: :route,
      convert: "settleRegentLane(bytes32,uint256,uint256)",
      converted: "RegentLaneSettled(bytes32,uint256,uint256)",
      kinds: @kinds
    },
    {:robinhood, :stocks} => %{
      lab: RobinhoodLab,
      abi: RobinhoodLabAbi,
      route: :stock_route,
      convert: "settleProtocolLane(bytes32,uint256,uint256)",
      converted: "ProtocolLaneSettled(bytes32,uint256,uint256)",
      kinds: @kinds
    }
  }
  @token_decimals 18
  # The floor a conversion may ask for: the sale refuses less than 95% of the
  # stock's worth at the Chainlink price. The routes themselves take any price
  # above the minimum the sale names.
  @floor_bps 9_500
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
  The steps of one action on a graduated launch's splitter for `address`, one
  of the signed-in account's wallets, with the facts the page shows beside
  them and what the page needs to read each step's result. The launch is
  `%{chain: :base, auction: auction_record}` or
  `%{chain: :robinhood, auction: auction_record}`. `:stake` and `:unstake`
  take the token amount typed and `:convert` the stock amount, with `floor:
  true` to refuse less than 95% of the Chainlink price and `false` for no
  minimum; the other four take nothing.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{kind: kind, launch: launch} = request, address, opts) when kind in @kinds do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, pool} <- pool(launch),
         true <- kind in venue(pool).kinds || unavailable(:unknown_action),
         :ok <- converter(kind, pool, signer),
         :ok <- vests(kind, pool),
         {:ok, config} <- lab(venue(pool)),
         {:ok, contracts} <- contracts(pool, venue(pool), config),
         {:ok, wallet} <- position(pool, signer),
         {:ok, amount} <- amount(kind, Map.get(request, :amount), wallet),
         {:ok, amount} <-
           conversion(kind, amount, Map.get(request, :floor), pool, config, contracts),
         do: {:ok, build(kind, pool, config, contracts, wallet, amount)}
  end

  def prepare(_request, _address, _opts), do: unavailable(:unknown_action)

  @doc "A whole-percent share of an amount from `position/2`, as the exact amount to type."
  @spec portion(%{atomic: non_neg_integer(), decimals: non_neg_integer()}, 1..100) :: String.t()
  def portion(%{atomic: atomic, decimals: decimals}, percent) when percent in 1..100,
    do: Rpc.format_units(div(atomic * percent, 100), decimals)

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

  # Only a second-launchpad memestock launch vests anything to its creator.
  defp vests(:release, %{vesting: nil}), do: unavailable(:unknown_action)
  defp vests(_kind, _pool), do: :ok

  # The stock amount to sell from REGENT's lane and the least the sale may
  # bring. With the floor, that is 95% of what the stock's route says it is
  # worth at the Chainlink price right now; without it there is no minimum and
  # Chainlink is not asked. The hook reads the stock's route from the launchpad
  # when it sells, so the quote comes from that same route.
  defp conversion(:convert, value, floor, pool, config, contracts) when is_boolean(floor) do
    venue = venue(pool)
    rpc = venue.lab.rpc_opts(config)

    with {:ok, stock} <- parsed(value, pool.currency.decimals),
         true <- stock <= pool.fees.regent.accrued_atomic || unavailable(:amount_above_share),
         {:ok, route} <- route(contracts, pool, rpc) do
      least(floor, stock, fn -> quote(venue, config, route, pool, stock, rpc) end)
    end
  end

  defp conversion(:convert, _value, _floor, _pool, _config, _contracts),
    do: unavailable(:unknown_action)

  defp conversion(_kind, amount, _floor, _pool, _config, _contracts), do: {:ok, amount}

  defp least(false, stock, _quote), do: {:ok, %{stock: stock, worth: nil, least: 0}}

  defp least(true, stock, quote) do
    with {:ok, worth} <- quote.(),
         do: {:ok, %{stock: stock, worth: worth, least: div(worth * @floor_bps, @bps)}}
  end

  defp route(contracts, pool, rpc) do
    abi = contracts.abis["launchpad"]
    data = LabAbi.encode(abi, "stockAdmission(address)", [pool.currency.address])

    with {:ok, [_admitted, _kind, route]} <-
           chain(Rpc.call_words(contracts.launchpad, data, pool.block, 3, rpc)) do
      case Abi.word_address(route) do
        {:ok, route} -> {:ok, route}
        :error -> unavailable(:no_route)
      end
    end
  end

  # The route refuses to quote while its Chainlink feed is stopped or stale;
  # a sale without the floor does not ask it.
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

  defp lab(venue) do
    case venue.lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:stake_unavailable)
    end
  end

  # The hook and locker the launch's actions go to, with their ABIs: a
  # Revstake launch's deployment, or a memestock launch's own contracts
  # version, with its launchpad too.
  defp contracts(%{kind: :agent} = pool, venue, config),
    do:
      {:ok,
       %{
         hook: pool.hook,
         locker: venue.lab.address!(config, :lp_locker),
         abis: %{
           "hook" => venue.lab.abi!(config, :hook),
           "locker" => venue.lab.abi!(config, :lp_locker)
         }
       }}

  defp contracts(%{kind: :stocks, version: version}, venue, config) do
    case venue.lab.contracts(config, version) do
      {:ok, contracts} -> {:ok, contracts}
      {:error, _reason} -> unavailable(:stake_unavailable)
    end
  end

  # The review

  defp build(kind, pool, config, contracts, wallet, amount) do
    venue = venue(pool)

    %{
      kind: kind,
      chain: Client.chain(config),
      steps: reviewed_steps(kind, pool, {venue, config, contracts}, wallet, amount),
      facts: review(kind, pool, wallet, amount),
      context: %{
        venue: venue,
        splitter: pool.fees.splitter.address,
        hook: contracts.hook,
        locker: contracts.locker,
        token: pool.token.address,
        token_symbol: pool.token.symbol,
        currency: pool.currency.address,
        currency_symbol: pool.currency.symbol,
        currency_decimals: pool.currency.decimals,
        dollar: pool.fees.splitter.dollar.address,
        dollar_symbol: pool.fees.splitter.dollar.symbol,
        dollar_decimals: pool.fees.splitter.dollar.decimals,
        # A Revstake launch has no launchpad.
        launchpad: contracts[:launchpad],
        amount_atomic: amount_atomic(amount)
      }
    }
  end

  defp amount_atomic(nil), do: nil
  defp amount_atomic(%{stock: stock}), do: stock
  defp amount_atomic(amount), do: amount

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

  defp review(:release, pool, _wallet, _amount) do
    [
      ["Paid to the creator", pool.vesting.creator],
      ["Ready to release", "#{pool.vesting.releasable} #{pool.token.symbol}"],
      ["Released so far", "#{pool.vesting.released} #{pool.token.symbol}"]
    ]
  end

  defp review(:collect, pool, _wallet, _amount) do
    Enum.map(pool.positions, fn position ->
      [position.label <> " position", uncollected_copy(position.uncollected, pool)]
    end)
  end

  defp review(:convert, pool, _wallet, %{stock: stock, worth: nil}) do
    currency = pool.currency

    [
      ["Waiting in REGENT's share", "#{pool.fees.regent.accrued} #{currency.symbol}"],
      ["You convert", "#{units(stock, currency.decimals)} #{currency.symbol}"],
      ["Least accepted", "No minimum"]
    ]
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

  # The steps, one calldata each, exactly what the wallet sends.
  defp reviewed_steps(:stake, pool, {venue, config, _contracts}, wallet, amount) do
    splitter = pool.fees.splitter.address

    approval(pool.token.address, splitter, amount, wallet.allowance) ++
      [step("stake", splitter, splitter_data(venue, config, "stake(uint256)", [amount]))]
  end

  defp reviewed_steps(:unstake, pool, {venue, config, _contracts}, _wallet, amount),
    do: [
      step(
        "unstake",
        pool.fees.splitter.address,
        splitter_data(venue, config, "unstake(uint256)", [amount])
      )
    ]

  defp reviewed_steps(:claim, pool, {venue, config, _contracts}, _wallet, _amount),
    do: [
      step("claim", pool.fees.splitter.address, splitter_data(venue, config, "claimAll()", []))
    ]

  defp reviewed_steps(:settle, pool, {_venue, _config, contracts}, _wallet, _amount) do
    data = LabAbi.encode(contracts.abis["hook"], "settleStakerLane(bytes32)", [pool.pool_id])

    [step("settle", contracts.hook, data)]
  end

  defp reviewed_steps(:release, pool, {_venue, _config, contracts}, _wallet, _amount) do
    data =
      LabAbi.encode(contracts.abis["launchpad"], "releaseCreatorVesting(uint256)", [
        pool.launch_id
      ])

    [step("release", contracts.launchpad, data)]
  end

  defp reviewed_steps(:collect, pool, {_venue, _config, contracts}, _wallet, _amount) do
    Enum.map(pool.positions, fn position ->
      step(
        "collect_" <> Atom.to_string(position.key),
        contracts.locker,
        LabAbi.encode(contracts.abis["locker"], "collect(uint256)", [position.token_id])
      )
    end)
  end

  defp reviewed_steps(:convert, pool, {venue, _config, contracts}, _wallet, %{
         stock: stock,
         least: least
       }) do
    data = LabAbi.encode(contracts.abis["hook"], venue.convert, [pool.pool_id, stock, least])

    [step("convert", contracts.hook, data)]
  end

  defp approval(_token, _spender, amount, allowance) when allowance >= amount, do: []

  defp approval(token, spender, amount, _allowance),
    do: [step("token_approval", token, Abi.encode_erc20("approve", [spender, amount]))]

  defp step(name, to, data), do: Review.step(name, to, data)

  defp splitter_data(venue, config, signature, arguments),
    do: LabAbi.encode(venue.lab.abi!(config, :splitter), signature, arguments)

  @doc """
  What one confirmed step moved, read from its receipt's logs, for the page to
  show; `nil` for an approval. `context` and `name` are the prepared action's
  and the step's own.
  """
  @spec result(map(), String.t(), [map()]) :: map() | nil
  def result(_context, "token_approval", _logs), do: nil
  def result(context, name, logs), do: moved(String.to_existing_atom(name), context, logs)

  defp moved(step, context, _logs) when step in [:stake, :unstake] do
    %{
      "kind" => Atom.to_string(step),
      "amount_units" => units(context.amount_atomic, @token_decimals),
      "token_symbol" => context.token_symbol
    }
  end

  # What the splitter's own claim records paid out, one entry per asset.
  defp moved(:claim, context, logs) do
    paid = emitted(logs, context.splitter, context.venue.abi.claimed_signature())

    per_token =
      Enum.reduce(paid, %{}, fn {[_account, token], [amount]}, sums ->
        Map.update(sums, token, amount, &(&1 + amount))
      end)

    %{
      "kind" => "claim",
      "dollar_units" => units(claimed(per_token, context.dollar), context.dollar_decimals),
      "token_units" => units(claimed(per_token, context.token), @token_decimals),
      "stock_units" => units(claimed(per_token, context.currency), context.currency_decimals),
      "dollar_symbol" => context.dollar_symbol,
      "token_symbol" => context.token_symbol,
      "currency_symbol" => context.currency_symbol
    }
  end

  defp moved(:settle, context, logs) do
    [{_topics, [amount]}] =
      emitted(logs, context.hook, context.venue.abi.staker_lane_settled_signature())

    %{
      "kind" => "settle",
      "settled_units" => units(amount, context.currency_decimals),
      "currency_symbol" => context.currency_symbol
    }
  end

  # A release with nothing vested yet succeeds and records nothing.
  defp moved(:release, context, logs) do
    amount =
      logs
      |> emitted(context.launchpad, context.venue.abi.creator_vesting_released_signature())
      |> Enum.reduce(0, fn {_topics, [amount]}, sum -> sum + amount end)

    %{
      "kind" => "release",
      "token_units" => units(amount, @token_decimals),
      "token_symbol" => context.token_symbol
    }
  end

  defp moved(step, context, logs)
       when step in [:collect_full_range, :collect_stock_only, :collect_new_only] do
    [{_topics, [currency0, _currency1, amount0, amount1]}] =
      emitted(logs, context.locker, context.venue.abi.fees_deposited_signature())

    {:ok, currency0} = Abi.word_address(currency0)

    {token, currency} =
      if Address.equal?(currency0, context.token),
        do: {amount0, amount1},
        else: {amount1, amount0}

    %{
      "kind" => "collect",
      "token_units" => units(token, @token_decimals),
      "currency_units" => units(currency, context.currency_decimals),
      "token_symbol" => context.token_symbol,
      "currency_symbol" => context.currency_symbol
    }
  end

  defp moved(:convert, context, logs) do
    [{_topics, [converted, deposited]}] = emitted(logs, context.hook, context.venue.converted)

    %{
      "kind" => "convert",
      "converted_units" => units(converted, context.currency_decimals),
      "currency_symbol" => context.currency_symbol,
      "dollar_units" => units(deposited, context.dollar_decimals),
      "dollar_symbol" => context.dollar_symbol
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
