defmodule Autolaunch.Stocks.StakeActions do
  @moduledoc """
  The one boundary between a wallet and a graduated Stocks launch's memestake
  splitter, its fee hook and its LP locker.

  Five reviewed actions, each one immutable envelope the wallet signs step by
  step: stake (the exact token allowance to the splitter when it is short, then
  the stake), unstake, claim (every reward the splitter holds for the wallet),
  settle (the hook's staker lane into the splitter, open to anyone) and collect
  (the locked positions' trading fees into the splitter, open to anyone).
  Nothing is written anywhere: the chain is the only record, and confirmation
  reads the canonical receipt.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time: the wallet the page presents must
  be exactly that wallet, never another linked address.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, Pool}
  alias Autolaunch.Stocks.{Amounts, LaunchOperations}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @resource "autolaunch_stake"
  @kinds [:stake, :unstake, :claim, :settle, :collect]
  @actions %{
    stake: "autolaunch_stake",
    unstake: "autolaunch_unstake",
    claim: "autolaunch_claim",
    settle: "autolaunch_settle_stakers",
    collect: "autolaunch_collect_fees"
  }
  @contract_names %{
    stake: "MemestockSplitterV1",
    unstake: "MemestockSplitterV1",
    claim: "MemestockSplitterV1",
    settle: "StocksFeeHookV1",
    collect: "MemestockLPLocker"
  }
  @steps [
    :token_approval,
    :stake,
    :unstake,
    :claim,
    :settle,
    :collect_full_range,
    :collect_stock_only
  ]
  @binding_keys [:launchpad, :hook, :locker]
  @token_decimals 18
  @dollar_decimals 6
  @uint128_max Integer.pow(2, 128) - 1
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  def kinds, do: @kinds

  @doc """
  What one wallet has in a launch's splitter, read at the block the pool facts
  were read at: its token balance, its stake, its allowance to the splitter and
  what it can claim in each of the three assets. A public read of public
  figures; nothing is bound to it.
  """
  @spec position(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def position(%{kind: :stocks} = pool, address) do
    splitter = pool.fees.splitter.address

    with {:ok, holder} <- address(address),
         {:ok, config} <- stocks_lab(),
         rpc <- StocksLab.rpc_opts(config),
         abi <- StocksLab.abi!(config, :splitter),
         {:ok, balance} <- erc20(pool.token.address, "balance_of", [holder], pool.block, rpc),
         {:ok, allowance} <-
           erc20(pool.token.address, "allowance", [holder, splitter], pool.block, rpc),
         {:ok, staked} <-
           splitter_uint(splitter, abi, "stakedOf(address)", [holder], pool.block, rpc),
         {:ok, dollar} <- claimable(splitter, abi, pool.fees.splitter.dollar, holder, pool, rpc),
         {:ok, token} <- claimable(splitter, abi, pool.token.address, holder, pool, rpc),
         {:ok, stock} <- claimable(splitter, abi, pool.currency.address, holder, pool, rpc) do
      {:ok,
       %{
         balance: amount(balance, @token_decimals),
         staked: amount(staked, @token_decimals),
         allowance: allowance,
         claimable: %{
           dollar: amount(dollar, @dollar_decimals),
           token: amount(token, @token_decimals),
           stock: amount(stock, pool.currency.decimals)
         }
       }}
    end
  end

  def position(_pool, _address), do: unavailable(:stake_unavailable)

  @doc """
  Reviews one action on a graduated Stocks auction's splitter for the signed-in
  wallet. `:stake` and `:unstake` take the amount typed; the other three take
  nothing.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{kind: kind, auction: auction} = request, address, opts) when kind in @kinds do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, pool} <- pool(auction),
         {:ok, config} <- stocks_lab(),
         {:ok, wallet} <- position(pool, signer),
         {:ok, amount} <- amount(kind, Map.get(request, :amount), wallet),
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
         {:ok, config} <- stocks_lab(),
         true <-
           StocksLab.binding(config, @binding_keys) == envelope["metadata"]["lab"] ||
             unavailable(:lab_config_changed),
         %{} = sent <- reviewed_step(envelope, step) || unavailable(:unknown_step),
         rpc <- StocksLab.rpc_opts(config),
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

  defp amount(_kind, _value, _wallet), do: {:ok, nil}

  defp parsed(value) when is_binary(value) do
    case Amounts.parse_units(value, @token_decimals) do
      {:ok, amount} when amount in 1..@uint128_max -> {:ok, amount}
      {:ok, 0} -> unavailable(:amount_required)
      {:ok, _too_large} -> unavailable(:amount_too_large)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp parsed(_value), do: unavailable(:amount_required)

  # The pool

  defp pool(auction) do
    case Pool.read(auction) do
      {:ok, %{kind: :stocks} = pool} -> {:ok, pool}
      {:ok, _agent} -> unavailable(:stake_unavailable)
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, _reason} -> unavailable(:stake_unavailable)
    end
  end

  defp stocks_lab do
    case StocksLab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:stake_unavailable)
    end
  end

  # The review

  defp build(kind, pool, config, signer, wallet, amount) do
    steps = reviewed_steps(kind, pool, config, wallet, amount)
    last = List.last(steps)

    envelope =
      @actions
      |> Map.fetch!(kind)
      |> Envelope.new(signer, last["data"],
        to: last["to"],
        resource: @resource,
        contract_name: Map.fetch!(@contract_names, kind),
        chain_id: StocksLab.chain_id(),
        lab_binding: StocksLab.binding(config, @binding_keys),
        risk_copy: risk_copy(kind, pool, amount),
        arguments: %{
          "kind" => Atom.to_string(kind),
          "pool_id" => pool.pool_id,
          "splitter" => pool.fees.splitter.address,
          "hook" => pool.hook,
          "locker" => StocksLab.address!(config, :locker),
          "token" => pool.token.address,
          "token_symbol" => pool.token.symbol,
          "currency" => pool.currency.address,
          "currency_symbol" => pool.currency.symbol,
          "currency_decimals" => pool.currency.decimals,
          "dollar" => pool.fees.splitter.dollar,
          "amount_atomic" => amount && Integer.to_string(amount),
          "block_number" => pool.block.number,
          "block_hash" => pool.block.hash,
          "steps" => steps
        }
      )
      |> stored()

    %{kind: kind, envelope: envelope, steps: steps, review: review(kind, pool, wallet, amount)}
  end

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
      ["USDC", wallet.claimable.dollar.shown],
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

  defp uncollected_copy(nil, _pool), do: "Not readable right now"

  defp uncollected_copy(%{token_amount: token, currency_amount: currency}, pool),
    do: "#{token} #{pool.token.symbol} · #{currency} #{pool.currency.symbol}"

  defp risk_copy(:stake, pool, amount),
    do:
      "Your wallet stakes #{units(amount, @token_decimals)} #{pool.token.symbol} in this launch's staking contract on the local Base fork with test assets and no mainnet value. You can unstake later; not right after staking."

  defp risk_copy(:unstake, pool, amount),
    do:
      "Your wallet takes #{units(amount, @token_decimals)} #{pool.token.symbol} back out of this launch's staking contract on the local Base fork with test assets and no mainnet value."

  defp risk_copy(:claim, pool, _amount),
    do:
      "Your wallet claims every reward this launch's staking contract holds for it, in USDC, #{pool.token.symbol} and #{pool.currency.symbol}, on the local Base fork with test assets and no mainnet value."

  defp risk_copy(:settle, pool, _amount),
    do:
      "Your wallet moves the #{pool.currency.symbol} waiting in the stakers' fee lane into this launch's staking contract, for every staker, on the local Base fork with test assets and no mainnet value. Nothing comes to your wallet."

  defp risk_copy(:collect, pool, _amount),
    do:
      "Your wallet collects the locked liquidity's trading fees into this launch's staking contract, for every #{pool.token.symbol} staker, on the local Base fork with test assets and no mainnet value. Nothing comes to your wallet."

  # The reviewed sequence, one calldata per step, exactly what the wallet sends.
  defp reviewed_steps(:stake, pool, config, wallet, amount) do
    splitter = pool.fees.splitter.address

    approval(pool.token.address, splitter, amount, wallet.allowance) ++
      [step("stake", splitter, splitter_data(config, "stake(uint256)", [amount]))]
  end

  defp reviewed_steps(:unstake, pool, config, _wallet, amount),
    do: [
      step(
        "unstake",
        pool.fees.splitter.address,
        splitter_data(config, "unstake(uint256)", [amount])
      )
    ]

  defp reviewed_steps(:claim, pool, config, _wallet, _amount),
    do: [step("claim", pool.fees.splitter.address, splitter_data(config, "claimAll()", []))]

  defp reviewed_steps(:settle, pool, config, _wallet, _amount) do
    data =
      LabAbi.encode(StocksLab.abi!(config, :hook), "settleStakerLane(bytes32)", [pool.pool_id])

    [step("settle", pool.hook, data)]
  end

  defp reviewed_steps(:collect, pool, config, _wallet, _amount) do
    locker = StocksLab.address!(config, :locker)
    abi = StocksLab.abi!(config, :locker)

    Enum.map(pool.positions, fn position ->
      step(
        "collect_" <> Atom.to_string(position.key),
        locker,
        LabAbi.encode(abi, "collect(uint256)", [position.token_id])
      )
    end)
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

  defp splitter_data(config, signature, arguments),
    do: LabAbi.encode(StocksLab.abi!(config, :splitter), signature, arguments)

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
    %{outcome: :confirmed, result: result(step, envelope["arguments"], logs)}
  end

  defp result(step, arguments, _logs) when step in [:stake, :unstake] do
    %{
      "kind" => Atom.to_string(step),
      "amount_units" => units(String.to_integer(arguments["amount_atomic"]), @token_decimals),
      "token_symbol" => arguments["token_symbol"]
    }
  end

  # What the splitter's own claim records paid out, one entry per asset.
  defp result(:claim, arguments, logs) do
    paid = emitted(logs, arguments["splitter"], StocksLabAbi.claimed_signature())

    per_token =
      Enum.reduce(paid, %{}, fn {[_account, token], [amount]}, sums ->
        Map.update(sums, token, amount, &(&1 + amount))
      end)

    %{
      "kind" => "claim",
      "dollar_units" => units(claimed(per_token, arguments["dollar"]), @dollar_decimals),
      "token_units" => units(claimed(per_token, arguments["token"]), @token_decimals),
      "stock_units" =>
        units(claimed(per_token, arguments["currency"]), arguments["currency_decimals"]),
      "token_symbol" => arguments["token_symbol"],
      "currency_symbol" => arguments["currency_symbol"]
    }
  end

  defp result(:settle, arguments, logs) do
    [{_topics, [amount]}] =
      emitted(logs, arguments["hook"], StocksLabAbi.staker_lane_settled_signature())

    %{
      "kind" => "settle",
      "settled_units" => units(amount, arguments["currency_decimals"]),
      "currency_symbol" => arguments["currency_symbol"]
    }
  end

  defp result(collect, arguments, logs)
       when collect in [:collect_full_range, :collect_stock_only] do
    [{_topics, [currency0, _currency1, amount0, amount1]}] =
      emitted(logs, arguments["locker"], StocksLabAbi.fees_deposited_signature())

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
