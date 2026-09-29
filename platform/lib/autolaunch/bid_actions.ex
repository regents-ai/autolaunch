defmodule Autolaunch.BidActions do
  @moduledoc """
  The one boundary between a bidder and Base.

  Preparation reads Base once, proves the auction really raises the bound REGENT,
  and writes the whole reviewed sequence as a single immutable envelope. Every
  durable write after that runs inside `SessionAuthority.transact_lease/3` as the
  outermost transaction, against the account that callback locked, so a claim, a
  bound hash or a settled outcome cannot outlive a concurrent logout.

  Provider reads always happen before the lease transaction; only the row write
  happens inside it, and the row is taken `FOR UPDATE` first, so two sockets
  racing the same step serialize and exactly one of them wins.
  """

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}

  alias Autolaunch.Chain.{Abi, Address, AuctionAbi, Envelope, Permit2Abi, Rpc}

  alias Autolaunch.{
    BidOperation,
    ChainClient,
    Lab,
    LabAbi,
    LabProjection,
    LabRpc,
    TreasurySecurity
  }

  @actor %System{}
  @domain Autolaunch

  @resource "autolaunch_auction"
  @contract_name "IContinuousClearingAuction"
  @action "submit_bid"
  @risk "Your wallet signs only the steps this bid still needs, then the bid itself."

  # The auction's currency has to be the bound REGENT, so a bid amount is always
  # REGENT's eighteen decimals.
  @decimals 18
  @q96 79_228_162_514_264_337_593_543_950_336
  @uint128_max Integer.pow(2, 128) - 1
  @uint256_max Integer.pow(2, 256) - 1

  # The reviewed envelope lives ten minutes, so a Permit2 allowance that would
  # lapse inside that window is granted again rather than relied on, and a
  # granted one outlives the review it belongs to without lingering.
  @review_seconds 600
  @permit2_seconds 900

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed bid expired before it was sent"
  @unresolved "account started a new bid while this one was unresolved"
  @reverted "verified revert on Base"
  @contradicted "canonical receipt contradicts the reviewed bid"

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @hash_attributes %{
    token_approval: :token_approval_transaction_hash,
    permit2_approval: :permit2_approval_transaction_hash,
    bid: :bid_transaction_hash
  }

  # Everything a Base read was answered about. A settlement applies only to a row
  # still carrying all of it.
  @identity [:state, :step, :envelope | Map.values(@hash_attributes)]

  @doc "The public estimate for one auction, from its stored snapshot."
  def quote(auction_id, amount, max_price, opts \\ []) do
    with {:ok, auction} <- auction(auction_id, opts),
         {:ok, amount} <- positive_decimal(amount),
         {:ok, max_price} <- positive_decimal(max_price) do
      current_price = nonnegative_decimal_or_zero(auction.current_clearing_price)
      projected_price = if Decimal.gt?(current_price, 0), do: current_price, else: max_price
      active? = Decimal.compare(max_price, current_price) != :lt

      estimated_tokens =
        if active? and Decimal.gt?(projected_price, 0),
          do: Decimal.div(amount, projected_price),
          else: Decimal.new(0)

      {:ok,
       %{
         auction_id: auction.id,
         amount: decimal_string(amount),
         max_price: decimal_string(max_price),
         quote_token: %{
           address: auction.quote_token_address,
           symbol: auction.quote_token_symbol,
           decimals: auction.quote_token_decimals
         },
         current_clearing_price: decimal_string(current_price),
         projected_clearing_price: decimal_string(projected_price),
         would_be_active_now: active?,
         status_band: status_band(active?, max_price, projected_price),
         estimated_tokens_if_end_now: decimal_string(estimated_tokens),
         warnings: quote_warnings(auction, active?)
       }}
    end
  end

  @doc """
  What the wallet Privy has selected may actually spend on this auction.

  The reported address is untrusted: it is proved against the account the mounted
  lease resolves to before any private fact is read, so a wallet the account does
  not hold is refused rather than answered about.
  """
  def position(input, %{actor: %Human{}} = context) do
    with {:ok, signer} <- current_wallet(input.arguments.expected_signer, context),
         {:ok, auction} <- auction(input.arguments.auction_id),
         {:ok, auction_address} <- normalize(auction.auction_address),
         {:ok, snapshot} <- snapshot(auction_address, signer, nil),
         :ok <- bound_currency(snapshot) do
      {:ok, %{signer: signer, balance: Integer.to_string(snapshot.regent_balance)}}
    end
  end

  def position(_input, _context), do: {:error, :authentication_required}

  @doc """
  Reviews one bid: one snapshot, one immutable sequence, one durable operation.

  The sequence carries only the transactions this wallet still needs — an exact
  REGENT approval to canonical Permit2, an exact short-lived Permit2 allowance
  for this auction, then the canonical five-argument bid.
  """
  def prepare(input, %{actor: %Human{}} = context) do
    arguments = input.arguments

    with {:ok, signer} <- current_wallet(arguments.expected_signer, context),
         {:ok, lease} <- lease(context),
         {:ok, auction} <- biddable(arguments.auction_id),
         {:ok, treasury_report} <- verified_treasury(auction),
         {:ok, address} <- normalize(auction.auction_address),
         {:ok, amount} <- refusable(atomic_amount(arguments.amount)),
         {:ok, max_price_q96} <- refusable(price_q96(arguments.max_price)),
         {:ok, snapshot} <- snapshot(address, signer, max_price_q96),
         {:ok, max_price_q96} <- refusable(Autolaunch.BidPrice.align(max_price_q96, snapshot)),
         :ok <- bound_currency(snapshot),
         :ok <- bounded_predecessor(snapshot, max_price_q96),
         :ok <- affordable(snapshot, amount),
         {envelope, step} <-
           review(
             auction,
             address,
             signer,
             amount,
             max_price_q96,
             snapshot,
             treasury_report,
             arguments.max_price
           ),
         {:ok, operation} <- open(lease, envelope, signer, step) do
      {:ok, %{operation: view(operation)}}
    end
  end

  def prepare(_input, _context), do: {:error, :authentication_required}

  @doc """
  Claims the current step's dispatch. Only this winner may open the wallet.

  The locked account and the signer the stored envelope pinned decide together,
  inside the transaction that takes the row, so a wallet the account no longer
  holds cannot be handed a dispatch by a check that passed a moment earlier.
  """
  def claim_dispatch(input, %{actor: %Human{}} = context) do
    action_id = input.arguments.action_id

    with {:ok, lease} <- lease(context),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, lab_status} <- dispatch_lab_status(candidate),
         treasury_result <- revalidate_treasury(candidate) do
      transact(
        lease,
        &locked_transition(&1, action_id, fn account, operation ->
          claim(account, operation, lab_status, treasury_result)
        end)
      )
    end
  end

  def claim_dispatch(_input, _context), do: unavailable(:authentication_required)

  @doc """
  Binds the first valid hash for the step the browser was actually sent.

  The step travels with the hash and has to be the one the row is on, so a
  callback delayed past an advance can never land in a later step's column. An
  exact replay is a no-op so a browser replaying a lost callback cannot fail, a
  different hash is refused rather than overwriting the submitted identity, and
  a hash recovered after the operation ended attaches without reopening it.
  """
  def bind_hash(%{arguments: %{step: step} = arguments}, context) do
    with {:ok, hash} <- canonical_hash(arguments.transaction_hash),
         do: write(context, arguments.action_id, fn _account, op -> bind(op, step, hash) end)
  end

  @doc """
  Reads the exact bound hash and records whatever it truthfully settles as.

  Base is read from the candidate row alone, before any lease transaction opens,
  so no provider call ever happens under a row lock. The locked row then has to
  still be that same candidate — same state, step, bound hashes and reviewed
  envelope — or the outcome is dropped rather than applied to a step it never
  described.

  A hash the chain has not resolved writes nothing at all, so the same hash can
  be read again later; an approval advances the sequence only once its own
  allowance really holds, and only the auction's own event confirms a bid.
  """
  def verify(input, %{actor: %Human{}} = context) do
    action_id = input.arguments.action_id

    with {:ok, lease} <- lease(context),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, outcome} <- read_chain(candidate),
         do: transact(lease, &locked_transition(&1, action_id, settle(candidate, outcome)))
  end

  def verify(_input, _context), do: unavailable(:authentication_required)

  def cancel(input, context),
    do: write(context, input.arguments.action_id, transition(:cancel, %{reason: @withdrawn}))

  def close_not_sent(input, context),
    do:
      write(context, input.arguments.action_id, transition(:close_not_sent, %{reason: @rejected}))

  def release_unstarted(input, context),
    do: write(context, input.arguments.action_id, transition(:release_unstarted, %{}))

  @doc """
  Ends an operation whose claimed step never resolved, at the account's request.

  Its calldata is never resent and its bound hashes stay exactly where they are.
  The row remains for the canonical projector; only the account's open slot is
  released, and a new review is a new bid, which the protocol permits.
  """
  def start_new_bid(input, context),
    do:
      write(
        context,
        input.arguments.action_id,
        fn _account, op ->
          # New presses do not mutate the review's prepared state. Withdrawing
          # that review cancels future admission, never its issued attempts.
          action = if op.state == :prepared, do: :cancel, else: :close_submission_unknown
          update(op, action, %{reason: @unresolved})
        end
      )

  @doc "The account's open operation, recovered without a lease and writing nothing."
  def open_operation(_input, %{actor: %Human{} = actor}) do
    with {:ok, operation} <- open_row(actor.human_account_id, false),
         do: {:ok, %{operation: view(operation)}}
  end

  def open_operation(_input, _context), do: {:error, :authentication_required}

  @doc "The presenter's whole view of one operation. Everything else stays server-side."
  @spec view(Ash.Resource.record() | nil) :: map() | nil
  def view(nil), do: nil

  def view(operation) do
    Map.take(operation, [
      :action_id,
      :state,
      :step,
      :signer,
      :envelope,
      :onchain_bid_id,
      :terminal_at
      | Map.values(@hash_attributes)
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :bid)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  @spec steps(map()) :: [map()]
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  @doc "The hash bound for one step of an operation, or `nil`."
  @spec step_hash(map(), String.t()) :: String.t() | nil
  def step_hash(operation, step),
    do: Map.get(operation, Map.fetch!(@hash_attributes, String.to_existing_atom(step)))

  # Reviews and operations

  defp review(
         auction,
         address,
         signer,
         amount,
         max_price_q96,
         snapshot,
         treasury_report,
         requested_price
       ) do
    granted = DateTime.add(Envelope.current_time(), @permit2_seconds, :second)

    {data, envelope_options} = bid_data(max_price_q96, amount, signer, snapshot)

    steps =
      required_steps(snapshot, amount, DateTime.to_unix(granted)) ++
        [%{"step" => "bid", "to" => address, "data" => data}]

    envelope =
      Envelope.new(
        @action,
        signer,
        data,
        envelope_options ++
          [
            to: address,
            resource: @resource,
            contract_name: @contract_name,
            risk_copy: risk_copy(snapshot),
            arguments:
              %{
                "auction_id" => auction.id,
                "amount" => units(amount),
                "amount_atomic" => Integer.to_string(amount),
                "max_price" => Autolaunch.BidPrice.decimal(max_price_q96),
                "requested_max_price" => requested_price,
                "tick_spacing_q96" => Integer.to_string(snapshot.tick_spacing_q96),
                "floor_price_q96" => Integer.to_string(snapshot.floor_price_q96),
                "clearing_price_q96" => Integer.to_string(snapshot.clearing_price_q96),
                "max_bid_price_q96" => Integer.to_string(snapshot.max_bid_price_q96),
                "max_price_q96" => Integer.to_string(max_price_q96),
                "prev_tick_price_q96" => Integer.to_string(snapshot.prev_tick_price_q96),
                "predecessor_source" => snapshot.predecessor_source,
                "currency" => snapshot.currency,
                "permit2" => permit2_address(snapshot),
                "treasury_security" => treasury_binding(treasury_report),
                "token_allowance_atomic" => Integer.to_string(snapshot.token_allowance),
                "permit2_allowance_atomic" => Integer.to_string(snapshot.permit2_amount),
                "permit2_expiration" => Integer.to_string(snapshot.permit2_expiration),
                "steps" => steps
              }
              |> Map.merge(lab_review_anchor(snapshot))
          ]
      )

    {stored(envelope), steps |> hd() |> Map.fetch!("step") |> String.to_existing_atom()}
  end

  defp bid_data(max_price_q96, amount, signer, %{lab_binding: binding} = snapshot) do
    config = Lab.current!()

    data =
      LabAbi.encode(
        Lab.abi!(config, :auction),
        "submitBid(uint256,uint128,address,uint256,bytes)",
        [max_price_q96, amount, signer, snapshot.prev_tick_price_q96, "0x"]
      )

    {data, [chain_id: Lab.chain_id(), lab_binding: binding]}
  end

  defp bid_data(max_price_q96, amount, signer, snapshot),
    do:
      {AuctionAbi.encode_submit_bid(
         max_price_q96,
         amount,
         signer,
         snapshot.prev_tick_price_q96
       ), []}

  defp risk_copy(%{lab_binding: _binding}),
    do:
      "Your wallet signs only the local-fork approval steps this bid still needs, then the test bid. These assets have no mainnet value."

  defp risk_copy(_snapshot), do: @risk

  defp lab_review_anchor(%{lab_binding: _binding, block: block}),
    do: %{"block_number" => block.number, "block_hash" => block.hash}

  defp lab_review_anchor(_snapshot), do: %{}

  # Only the transactions this wallet still needs. An allowance that already
  # covers the amount and outlives the review is spent exactly as it stands.
  defp required_steps(snapshot, amount, expiration) do
    token_approval(snapshot, amount) ++ permit2_approval(snapshot, amount, expiration)
  end

  defp token_approval(%{token_allowance: allowance}, amount) when allowance >= amount, do: []

  defp token_approval(snapshot, amount),
    do: [
      %{
        "step" => "token_approval",
        "to" => snapshot.currency,
        "data" => encode_token_approval(snapshot, amount),
        "amount" => Integer.to_string(amount)
      }
    ]

  defp permit2_approval(snapshot, amount, expiration) do
    if permit2_current?(snapshot, amount),
      do: [],
      else: [
        %{
          "step" => "permit2_approval",
          "to" => permit2_address(snapshot),
          "data" => encode_permit2_approval(snapshot, amount, expiration),
          "amount" => Integer.to_string(amount),
          "expiration" => Integer.to_string(expiration)
        }
      ]
  end

  # An existing allowance is reused only if it outlives the whole review window,
  # so the envelope's own deadline is always the one the sequence expires on.
  # Its expiry stays a plain integer: a canonical `uint48` maximum is a perfectly
  # good allowance and no calendar can hold it.
  defp permit2_current?(%{permit2_amount: allowed, permit2_expiration: expires}, amount),
    do:
      allowed >= amount and
        expires >= DateTime.to_unix(Envelope.current_time()) + @review_seconds

  defp permit2_address(%{permit2: address}), do: address
  defp permit2_address(_snapshot), do: Permit2Abi.address()

  defp encode_token_approval(%{lab_binding: _binding} = snapshot, amount) do
    config = Lab.current!()

    LabAbi.encode(
      Lab.abi!(config, :token),
      "approve(address,uint256)",
      [permit2_address(snapshot), amount]
    )
  end

  defp encode_token_approval(_snapshot, amount),
    do: Abi.encode_erc20("approve", [Permit2Abi.address(), amount])

  defp encode_permit2_approval(%{lab_binding: _binding} = snapshot, amount, expiration) do
    config = Lab.current!()

    LabAbi.encode(
      Lab.abi!(config, :permit2),
      "approve(address,address,uint160,uint48)",
      [snapshot.currency, snapshot.auction, amount, expiration]
    )
  end

  defp encode_permit2_approval(snapshot, amount, expiration),
    do: Permit2Abi.encode_approve(snapshot.currency, snapshot.auction, amount, expiration)

  defp open(lease, envelope, signer, step) do
    transact(lease, fn account ->
      with :ok <- signer_matches(account, signer),
           :ok <- release_undispatched(account.id) do
        BidOperation
        |> Ash.Changeset.for_create(
          :prepare,
          %{
            action_id: envelope["action_id"],
            envelope: envelope,
            signer: signer,
            step: step,
            human_account_id: account.id
          },
          domain: @domain,
          actor: @actor
        )
        |> Ash.create(actor: @actor)
      end
    end)
  end

  # A new prepare always cancels whatever is open as :replaced and proceeds.
  defp release_undispatched(account_id) do
    case open_row(account_id, true) do
      {:ok, nil} -> :ok
      {:ok, open} -> released(replace_open(open))
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_open(%{state: :prepared} = open),
    do: update(open, :cancel, %{reason: @replaced})

  defp replace_open(open),
    do: update(open, :close_submission_unknown, %{reason: @replaced})

  defp released({:ok, _cancelled}), do: :ok
  defp released(error), do: error

  # Read-only dispatch evidence, called before the authority/account/review locks.
  def press_evidence(operation) do
    with {:ok, :current} <- dispatch_lab_status(operation),
         {:ok, fresh} <- revalidate_treasury(operation),
         true <- treasury_still_reviewed?(operation, fresh),
         true <- valid_envelope?(operation),
         do: :ok,
         else: (_ -> unavailable(:treasury_security_changed))
  end

  # Transitions

  defp transition(action, input),
    do: fn _account, operation -> update(operation, action, input) end

  defp claim(account, operation, :current, {:ok, fresh_treasury}) do
    with :ok <- signer_matches(account, operation.signer),
         true <- valid_envelope?(operation),
         true <- treasury_still_reviewed?(operation, fresh_treasury) do
      update(operation, :claim_dispatch, %{})
    else
      false -> update(operation, :cancel, %{reason: "the reviewed network or treasury changed"})
      error -> error
    end
  end

  defp claim(account, operation, :changed, _treasury_result) do
    with :ok <- signer_matches(account, operation.signer),
         do: update(operation, :cancel, %{reason: "the reviewed local lab changed"})
  end

  defp claim(account, operation, :current, {:error, _reason}) do
    with :ok <- signer_matches(account, operation.signer),
         do: update(operation, :cancel, %{reason: "treasury security changed"})
  end

  defp bind(operation, step, hash) do
    attribute = Map.fetch!(@hash_attributes, step)

    case Map.fetch!(operation, attribute) do
      ^hash -> {:ok, operation}
      nil -> bind_step(operation, step, attribute, hash)
      _different -> unavailable(:submitted_hash_conflict)
    end
  end

  # The hash was produced for one exact step, so it may only ever land in that
  # step's own column, and only while the row is still on that step.
  defp bind_step(%{step: step} = operation, step, attribute, hash),
    do: update(operation, bind_action(operation), %{attribute => hash})

  defp bind_step(_operation, _step, _attribute, _hash), do: unavailable(:submitted_step_mismatch)

  defp bind_action(%{terminal_at: nil}), do: :bind_hash
  defp bind_action(_terminal), do: :attach_late_hash

  # The one Base read a settlement makes, with no transaction and no lock open.
  # A candidate with nothing sent to read about asks nothing.
  defp read_chain(%{state: :submitted} = candidate) do
    hash = Map.fetch!(candidate, Map.fetch!(@hash_attributes, candidate.step))

    case ChainClient.module().verify(candidate.envelope, candidate.step, hash) do
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      result -> result
    end
  end

  defp read_chain(_settled), do: {:ok, nil}

  # The read answered about one exact candidate. A locked row that has moved on
  # since — another socket bound a hash, advanced the step, or the account ended
  # the operation — is left exactly as it stands.
  defp settle(candidate, outcome) do
    fn _account, operation ->
      if identity(operation) == identity(candidate),
        do: record(operation, outcome),
        else: {:ok, operation}
    end
  end

  defp identity(operation), do: Map.take(operation, @identity)

  defp record(operation, %{outcome: :confirmed} = result), do: advance(operation, result)

  defp record(operation, %{outcome: :reverted}),
    do: update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: update(operation, :record_unverified, %{reason: @contradicted})

  # A hash the chain has not resolved yet, and a candidate that had nothing to
  # read, both leave the row bound and readable again.
  defp record(operation, _unresolved), do: {:ok, operation}

  defp advance(%{step: :bid} = operation, %{onchain_bid_id: bid_id} = result) do
    projection = Map.put(result[:result] || %{}, "onchain_bid_id", bid_id)

    with :ok <- LabProjection.project_bid(operation, projection) do
      update(operation, :confirm, %{onchain_bid_id: bid_id})
    end
  end

  defp advance(operation, _result), do: update(operation, :advance, %{step: next_step(operation)})

  defp next_step(%{envelope: envelope, step: step}) do
    current = Atom.to_string(step)

    envelope["arguments"]["steps"]
    |> Enum.map(& &1["step"])
    |> Enum.drop_while(&(&1 != current))
    |> Enum.at(1)
    |> String.to_existing_atom()
  end

  # The reviewed envelope lives ten minutes. Past that, no prepared step of it
  # can be spent, whether it is a lone bid or the remainder of a longer
  # sequence, so the operation ends here — inside the locked transaction, ahead
  # of the claim — and a new review rereads current allowance and auction state.
  defp expire_lapsed(%{state: :prepared} = operation) do
    if expired?(operation),
      do: update(operation, :expire, %{reason: @lapsed}),
      else: {:ok, operation}
  end

  defp expire_lapsed(operation), do: {:ok, operation}

  defp expired?(%{envelope: %{"expires_at" => expires_at}}) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
    DateTime.compare(expires_at, Envelope.current_time()) != :gt
  end

  # Durable write plumbing

  defp write(%{actor: %Human{}} = context, action_id, transition) do
    with {:ok, lease} <- lease(context),
         do: transact(lease, &locked_transition(&1, action_id, transition))
  end

  defp write(_context, _action_id, _transition), do: unavailable(:authentication_required)

  defp locked_transition(account, action_id, transition) do
    with {:ok, operation} <- operation(account.id, action_id, true),
         {:ok, operation} <- expire_lapsed(operation),
         {:ok, operation} <- resume(operation, account, transition),
         do: {:ok, %{operation: view(operation)}}
  end

  # An operation the lapse just ended is itself the outcome, and it commits:
  # nothing further is asked of a sequence that can no longer be spent.
  defp resume(%{state: :expired} = operation, _account, _transition), do: {:ok, operation}
  defp resume(operation, account, transition), do: transition.(account, operation)

  defp transact(%{lineage: lineage, account_id: account_id}, callback) do
    case SessionAuthority.transact_lease(lineage, account_id, callback) do
      {:error, :stale_authority} -> unavailable(:session_unavailable)
      result -> result
    end
  end

  defp operation(account_id, action_id, lock?) do
    BidOperation
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(action_id == ^action_id and human_account_id == ^account_id)
    |> then(&if lock?, do: Ash.Query.lock(&1, :for_update), else: &1)
    |> Ash.read_one(domain: @domain, actor: @actor)
    |> case do
      {:ok, nil} -> unavailable(:bid_operation_not_found)
      other -> other
    end
  end

  defp open_row(account_id, lock?) do
    BidOperation
    |> Ash.Query.for_read(:open, %{human_account_id: account_id}, domain: @domain, actor: @actor)
    |> then(&if lock?, do: Ash.Query.lock(&1, :for_update), else: &1)
    |> Ash.read_one(domain: @domain)
  end

  defp update(operation, action, input) do
    operation
    |> Ash.Changeset.for_update(action, input, domain: @domain, actor: @actor)
    |> Ash.update(actor: @actor)
  end

  # Session and wallet identity

  @doc "The mounted lease an Ash action context carries, or the refusal to write at all."
  @spec lease(map()) :: {:ok, map()} | {:error, :session_lease_required}
  def lease(%{source_context: %{session_lease: %{lineage: lineage, account_id: account_id}}})
      when is_binary(lineage) and is_integer(account_id),
      do: {:ok, %{lineage: lineage, account_id: account_id}}

  def lease(_context), do: unavailable(:session_lease_required)

  defp current_wallet(address, context) do
    with {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(context),
         :ok <- leased_wallet(lease, signer),
         do: {:ok, signer}
  end

  defp leased_wallet(%{lineage: lineage, account_id: account_id}, signer),
    do: lineage |> SessionAuthority.leased_account(account_id) |> signer_matches(signer)

  defp signer_matches(nil, _signer), do: unavailable(:session_unavailable)

  defp signer_matches(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets || [], &Address.equal?(&1, signer)),
      do: :ok,
      else: unavailable(:wrong_signer)
  end

  # Chain snapshot

  defp snapshot(address, signer, max_price_q96) do
    case ChainClient.module().snapshot(%{
           auction: address,
           signer: signer,
           max_price_q96: max_price_q96
         }) do
      {:ok, snapshot} -> {:ok, Map.put(snapshot, :auction, address)}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp bound_currency(%{
         currency: currency,
         lab_binding: %{"addresses" => %{"regent" => regent}}
       }) do
    if Address.equal?(currency, regent),
      do: :ok,
      else: unavailable(:auction_currency_is_not_regent)
  end

  defp bound_currency(%{currency: currency}) do
    if Address.equal?(currency, Abi.regent_address()),
      do: :ok,
      else: unavailable(:auction_currency_is_not_regent)
  end

  # The predecessor tick is the one argument no reviewed production source
  # supplies yet, so it has to be a word the auction could really hold below
  # this bid's own price, and it has to come from a source that names itself.
  defp bounded_predecessor(%{prev_tick_price_q96: hint} = snapshot, max_price_q96)
       when hint in 0..@uint256_max and hint < max_price_q96,
       do: reviewed_source(snapshot)

  defp bounded_predecessor(_snapshot, _max_price_q96),
    do: unavailable(:bid_preparation_unavailable)

  defp reviewed_source(%{predecessor_source: source}) when is_binary(source) and source != "",
    do: :ok

  defp reviewed_source(_unnamed), do: unavailable(:bid_preparation_unavailable)

  defp affordable(%{regent_balance: balance}, amount) when balance >= amount, do: :ok
  defp affordable(_snapshot, _amount), do: unavailable(:amount_above_balance)

  # Stored auctions

  defp auction(auction_id, opts \\ []) do
    case Autolaunch.get_public_auction(auction_id, Keyword.put(opts, :actor, nil)) do
      {:ok, nil} -> unavailable(:auction_not_found)
      result -> result
    end
  end

  defp biddable(auction_id) do
    case auction(auction_id) do
      {:ok, %{state: :active} = auction} -> {:ok, auction}
      {:ok, _closed} -> unavailable(:auction_not_biddable)
      error -> error
    end
  end

  defp verified_treasury(auction) do
    if Lab.enabled?(), do: lab_treasury(auction), else: verified_production_treasury(auction)
  end

  defp lab_treasury(%{
         id: auction_id,
         auction_address: auction_address,
         treasury_address: treasury_address
       }) do
    with {:ok, auction_address} <- normalize(auction_address),
         {:ok, treasury_address} <- normalize(treasury_address) do
      {:ok,
       %{
         "mode" => "local_lab",
         "auction_id" => auction_id,
         "auction_address" => auction_address,
         "address" => treasury_address
       }}
    end
  end

  defp lab_treasury(_auction), do: unavailable(:treasury_report_missing)

  defp verified_production_treasury(%{treasury_security_report: nil}),
    do: unavailable(:treasury_report_missing)

  defp verified_production_treasury(%{treasury_security_report: %Ash.NotLoaded{}}),
    do: unavailable(:treasury_report_missing)

  defp verified_production_treasury(%{
         treasury_address: address,
         treasury_security_report: %{address: address} = report
       }),
       do: TreasurySecurity.revalidate_bound(report)

  defp verified_production_treasury(_auction), do: unavailable(:treasury_security_changed)

  defp revalidate_treasury(operation) do
    binding = operation.envelope["arguments"]["treasury_security"]

    if binding["mode"] == "local_lab" do
      revalidate_lab_treasury(operation, binding)
    else
      revalidate_production_treasury(binding)
    end
  end

  defp revalidate_production_treasury(binding) do
    with {:ok, report} <-
           Autolaunch.get_treasury_security_report(binding["report_id"], actor: nil),
         false <- is_nil(report) do
      if report.address == binding["address"],
        do: TreasurySecurity.revalidate_bound(report),
        else: unavailable(:treasury_security_changed)
    else
      _missing -> unavailable(:treasury_report_missing)
    end
  end

  defp revalidate_lab_treasury(operation, binding) do
    with true <- lab_operation?(operation),
         {:ok, auction} <- auction(binding["auction_id"]),
         true <- Address.equal?(auction.auction_address, binding["auction_address"]),
         true <- Address.equal?(auction.treasury_address, binding["address"]),
         true <- Address.equal?(operation.envelope["to"], binding["auction_address"]),
         true <- Lab.binding_matches?(operation.envelope["metadata"]["lab"], [:regent, :permit2]) do
      {:ok, binding}
    else
      _changed -> unavailable(:treasury_security_changed)
    end
  end

  defp treasury_still_reviewed?(operation, %{"mode" => "local_lab"} = fresh),
    do:
      fresh == operation.envelope["arguments"]["treasury_security"] and
        lab_operation?(operation)

  defp treasury_still_reviewed?(operation, fresh) do
    bound = operation.envelope["arguments"]["treasury_security"]

    bound["configuration_fingerprint"] == fresh.configuration_fingerprint and
      bound["address"] == fresh.address and
      bound["classification"] == Atom.to_string(fresh.classification) and
      bound["verification_state"] == "verified" and fresh.verification_state == :verified and
      bound["downgrade_state"] == Atom.to_string(fresh.downgrade_state)
  end

  defp treasury_binding(%{"mode" => "local_lab"} = binding), do: binding

  defp treasury_binding(report) do
    %{
      "report_id" => report.id,
      "address" => report.address,
      "configuration_fingerprint" => report.configuration_fingerprint,
      "source_block_hash" => report.source_block_hash,
      "source_block_number" => report.source_block_number,
      "classification" => Atom.to_string(report.classification),
      "verification_state" => Atom.to_string(report.verification_state),
      "downgrade_state" => Atom.to_string(report.downgrade_state),
      "evidence" => %{
        "usdc" => report.usdc_evidence,
        "regent" => report.regent_evidence,
        "outbound" => report.outbound_evidence
      }
    }
  end

  defp valid_envelope?(operation) do
    options = [
      resource: @resource,
      action: @action,
      signer: operation.signer,
      to: operation.envelope["to"],
      contract_name: @contract_name
    ]

    options =
      if lab_operation?(operation),
        do: Keyword.put(options, :chain_id, Lab.chain_id()),
        else: options

    Envelope.valid?(operation.envelope, options) and
      (not lab_operation?(operation) or
         Lab.binding_matches?(operation.envelope["metadata"]["lab"], [:regent, :permit2]))
  end

  defp dispatch_lab_status(operation) do
    if lab_operation?(operation),
      do: current_lab_status(operation),
      else: {:ok, :current}
  end

  defp current_lab_status(operation) do
    binding = operation.envelope["metadata"]["lab"]

    case Lab.current() do
      {:ok, config} -> compare_lab_binding(operation, config, binding)
      {:error, _reason} -> {:ok, :changed}
    end
  end

  defp compare_lab_binding(operation, config, binding) do
    if Lab.binding(config, [:regent, :permit2]) == binding,
      do: verify_lab_target(operation),
      else: {:ok, :changed}
  end

  defp verify_lab_target(operation) do
    with {:ok, _current, block, opts} <- LabRpc.current([:regent, :permit2]),
         :ok <- LabRpc.ensure_contract(operation.envelope["to"], block, opts) do
      {:ok, :current}
    else
      {:error, reason} -> unavailable(reason)
    end
  end

  defp lab_operation?(operation),
    do: get_in(operation.envelope, ["metadata", "lab"]) != nil

  # Amounts and prices

  @doc """
  The one bid-amount language: exact decimal digits, at most eighteen places.

  The form validates against this, so the page never invites an amount that
  preparation would refuse.
  """
  @spec atomic_amount(term()) :: {:ok, pos_integer()} | {:error, atom()}
  def atomic_amount(value) when is_binary(value) do
    value = String.trim(value)

    with true <- String.match?(value, ~r/^\d+(?:\.\d{1,18})?$/),
         {decimal, ""} <- Decimal.parse(value),
         scaled <- Decimal.mult(decimal, Decimal.new(Integer.pow(10, @decimals))),
         rounded <- Decimal.round(scaled, 0),
         :eq <- Decimal.compare(scaled, rounded),
         amount when amount in 1..@uint128_max <- Decimal.to_integer(rounded) do
      {:ok, amount}
    else
      _refused -> {:error, :invalid_amount}
    end
  end

  def atomic_amount(_value), do: {:error, :invalid_amount}

  @doc "The exact decimal REGENT rendering of an atomic amount, never rounded up."
  @spec units(non_neg_integer()) :: String.t()
  def units(amount), do: Rpc.format_units(amount, @decimals)

  @doc "The exact Q96 price a decimal maximum price names."
  @spec price_q96(term()) :: {:ok, pos_integer()} | {:error, atom()}
  def price_q96(value) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 100 and String.match?(value, ~r/^\d+(?:\.\d+)?\z/),
         [whole | fraction] <- String.split(value, "."),
         fraction <- List.first(fraction) || "",
         numerator when numerator > 0 <- String.to_integer(whole <> fraction) do
      quotient = div(numerator * @q96, Integer.pow(10, byte_size(fraction)))
      if quotient in 1..@uint256_max, do: {:ok, quotient}, else: {:error, :invalid_price}
    else
      _ -> {:error, :invalid_decimal}
    end
  end

  def price_q96(_), do: {:error, :invalid_decimal}

  defp positive_decimal(value) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 100,
         true <- String.match?(value, ~r/^\d+(?:\.\d+)?$/),
         {decimal, ""} <- Decimal.parse(value),
         :gt <- Decimal.compare(decimal, 0) do
      {:ok, decimal}
    else
      _refused -> {:error, :invalid_decimal}
    end
  end

  defp positive_decimal(_value), do: {:error, :invalid_decimal}

  defp nonnegative_decimal_or_zero(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.compare(decimal, 0) in [:eq, :gt], do: decimal, else: Decimal.new(0)

      _unreadable ->
        Decimal.new(0)
    end
  end

  defp nonnegative_decimal_or_zero(_value), do: Decimal.new(0)

  defp decimal_string(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp status_band(false, _max_price, _projected_price), do: "inactive"

  defp status_band(true, max_price, projected_price) do
    if Decimal.equal?(max_price, projected_price), do: "borderline", else: "active"
  end

  defp quote_warnings(auction, active?) do
    []
    |> maybe_warning(not active?, "max_price_below_current_clearing_price")
    |> maybe_warning(auction.state != :active, "auction_not_biddable")
  end

  defp maybe_warning(warnings, true, warning), do: [warning | warnings]
  defp maybe_warning(warnings, false, _warning), do: warnings

  # Shared helpers

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  # The form asks the amount and price helpers the same question the page does,
  # so their plain answers become the one typed refusal here.
  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  # One stored shape: the envelope is written, read and rendered exactly as the
  # confirmation token signed it.
  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # A typed Ash error, so the refusal survives the action's error class and the
  # presenter can name the fact that actually stopped the bid.
  defp unavailable(reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: BidOperation, reason: reason)}
end
