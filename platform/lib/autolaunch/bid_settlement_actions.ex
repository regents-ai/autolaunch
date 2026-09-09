defmodule Autolaunch.BidSettlementActions do
  @moduledoc """
  The one boundary between a bidder and the auction after bidding has ended.

  Preparation reads the auction once, through `LabBidSettlementChainClient`,
  which lets the auction itself say what settling this bid position would do
  right now: whether the auction has ended, whether it graduated, whether the
  bid has been exited, what `exitBid` (or `exitPartiallyFilledBid` with derived
  checkpoint hints) would return, and what `claimTokens` would deliver. The
  exact eligible steps and their calldata are written as one immutable
  envelope; anything the auction refuses becomes a reason code rather than a
  wallet prompt.

  Every durable write after that runs inside `SessionAuthority.transact_lease/3`
  against the account that callback locked, with the row taken `FOR UPDATE`,
  exactly as `BidActions` does.
  """

  require Ash.Query

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.{Bid, BidSettlementOperation, Lab, LabBidSettlementChainClient, LabProjection}

  @actor %System{}
  @domain Autolaunch

  @resource "autolaunch_bid"
  @action "settle_bid"
  @contract_name "IContinuousClearingAuction"
  @new_decimals 18

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed settlement expired before it was sent"
  @unresolved "account started a new settlement while this one was unresolved"
  @reverted "verified revert on the local fork"
  @contradicted "canonical receipt contradicts the reviewed settlement"

  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @hash_attributes %{exit: :exit_transaction_hash, claim: :claim_transaction_hash}
  @identity [:state, :step, :envelope | Map.values(@hash_attributes)]

  @doc """
  Reviews one settlement: one snapshot, one immutable sequence, one operation.

  The sequence carries only the steps the auction would accept right now: the
  exit that returns unspent currency and records the fill, then the claim of
  the launch token when the auction graduated, the claim block has passed and
  the bid has fill. A position nothing can be done for yet is refused with the
  auction's own reason.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(bid_position_id, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, lease} <- lease(opts),
         {:ok, position} <- owned_position(bid_position_id, actor),
         :ok <- position_signer(position, signer),
         {:ok, bid_id} <- onchain_bid_id(position),
         {:ok, snapshot} <- snapshot(position.auction_address, bid_id, signer),
         :ok <- owner_matches(snapshot, signer),
         {:ok, steps} <- eligible_steps(snapshot, position),
         envelope <- review(position, signer, snapshot, steps),
         {:ok, operation} <- open(lease, position, signer, envelope) do
      {:ok, %{operation: presented(operation)}}
    end
  end

  @doc "Why nothing can be settled for this position right now, from the auction's own answer."
  @spec refusal_reason(map()) :: atom()
  def refusal_reason(snapshot) do
    case snapshot do
      %{exit: {:refused, :already_exited}, claim: {:refused, reason}} -> reason
      %{exit: {:refused, reason}} -> reason
    end
  end

  @doc "Claims the current step's dispatch. Only this winner may open the wallet."
  @spec claim_dispatch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_dispatch(action_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         :ok <- press_evidence(candidate) do
      transact(lease, &locked(&1, action_id, claiming(signer, candidate)))
    end
  end

  @doc "Binds the first valid hash for the step the browser was actually sent."
  @spec bind_hash(String.t(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind_hash(action_id, step, hash, opts) when step in [:exit, :claim] do
    with {:ok, hash} <- canonical_hash(hash),
         do: write(action_id, opts, fn _account, operation -> bind(operation, step, hash) end)
  end

  def bind_hash(_action_id, _step, _hash, _opts), do: unavailable(:unknown_step)

  @doc "Reads the exact bound hash and records whatever it truthfully settles as."
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(action_id, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, outcome} <- read_chain(candidate),
         do: transact(lease, &locked(&1, action_id, settle(candidate, outcome)))
  end

  def cancel(action_id, opts), do: write(action_id, opts, transition(:cancel, @withdrawn))

  def close_not_sent(action_id, opts),
    do: write(action_id, opts, transition(:close_not_sent, @rejected))

  def release_unstarted(action_id, opts),
    do: write(action_id, opts, transition(:release_unstarted, nil))

  def start_new(action_id, opts),
    do:
      write(action_id, opts, fn _account, operation ->
        action = if operation.state == :prepared, do: :cancel, else: :close_submission_unknown
        update(operation, action, %{reason: @unresolved})
      end)

  @doc "The account's open settlements by bid position id, recovered without a lease."
  @spec open_operations(keyword()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def open_operations(opts) do
    with {:ok, actor} <- human(opts),
         {:ok, rows} <-
           BidSettlementOperation
           |> Ash.Query.for_read(:open_for_account, %{human_account_id: actor.human_account_id},
             domain: @domain,
             actor: @actor
           )
           |> Ash.read(domain: @domain) do
      {:ok, Map.new(rows, &{&1.bid_position_id, presented(&1)})}
    end
  end

  @doc "One operation of the account, by action id, without a lease and writing nothing."
  @spec operation_view(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def operation_view(action_id, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, operation} <- operation(actor.human_account_id, action_id, false),
         do: {:ok, %{operation: presented(operation)}}
  end

  @doc "The presenter's whole view of one operation."
  def presented(nil), do: nil

  def presented(operation) do
    operation
    |> Map.take([
      :action_id,
      :bid_position_id,
      :state,
      :step,
      :signer,
      :envelope,
      :result,
      :reason,
      :exit_transaction_hash,
      :claim_transaction_hash,
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :bid_settlement)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  @doc "The hash bound for one step of an operation, or `nil`."
  def step_hash(operation, step) when step in ["exit", "claim"],
    do: step_hash(operation, String.to_existing_atom(step))

  def step_hash(operation, step) when step in [:exit, :claim],
    do: Map.get(operation, Map.fetch!(@hash_attributes, step))

  def step_hash(_operation, _unknown), do: nil

  @doc "Read-only dispatch evidence for a wallet press, before any lock is taken."
  def press_evidence(operation) do
    if valid_envelope?(operation), do: :ok, else: unavailable(:settlement_review_changed)
  end

  # Reviews

  # The exact eligible steps. The exit comes first whenever the auction accepts
  # it; the claim follows only when the auction would deliver tokens right after
  # that exit (graduated, claim block reached, fill above zero). An already
  # exited bid with claimable fill has only the claim.
  defp eligible_steps(%{exit: {:refused, :already_exited}, claim: %{} = claim}, _position),
    do: {:ok, [claim_step(claim)]}

  defp eligible_steps(%{exit: %{} = exit, claim: claim}, _position),
    do: {:ok, [exit_step(exit) | claim_steps(claim)]}

  defp eligible_steps(snapshot, _position), do: unavailable(refusal_reason(snapshot))

  defp claim_steps(%{} = claim), do: [claim_step(claim)]
  defp claim_steps({:refused, _reason}), do: []

  defp exit_step(exit) do
    %{
      "step" => "exit",
      "signature" => exit.signature,
      "data" => exit.data,
      "hints" => hints(exit.hints),
      "tokens_filled" => Integer.to_string(exit.tokens_filled),
      "currency_refunded" => Integer.to_string(exit.currency_refunded)
    }
  end

  defp claim_step(claim),
    do: %{
      "step" => "claim",
      "signature" => "claimTokens(uint256)",
      "data" => claim.data,
      "tokens_claimed" => Integer.to_string(claim.tokens_claimed)
    }

  defp hints(nil), do: nil

  defp hints(hints),
    do: %{
      "last_fully_filled_block" => Integer.to_string(hints.last_fully_filled_block),
      "outbid_block" => Integer.to_string(hints.outbid_block)
    }

  defp review(position, signer, snapshot, steps) do
    auction = position.auction
    decimals = auction.quote_token_decimals
    data = steps |> hd() |> Map.fetch!("data")
    exit = Enum.find(steps, &(&1["step"] == "exit"))
    claim = Enum.find(steps, &(&1["step"] == "claim"))

    steps = Enum.map(steps, &Map.put(&1, "to", snapshot.auction))

    @action
    |> Envelope.new(signer, data,
      to: snapshot.auction,
      resource: @resource,
      contract_name: @contract_name,
      chain_id: Lab.chain_id(),
      lab_binding: snapshot.lab_binding,
      risk_copy: risk_copy(exit, claim, auction),
      arguments: %{
        "bid_position_id" => position.id,
        "bid_id" => position.bid_id,
        "onchain_bid_id" => Integer.to_string(snapshot.bid.id),
        "auction_id" => auction.id,
        "auction_address" => snapshot.auction,
        "auction_kind" => Atom.to_string(auction.kind),
        "currency" => snapshot.currency,
        "currency_symbol" => auction.quote_token_symbol,
        "currency_decimals" => Integer.to_string(decimals),
        "token_symbol" => auction.token_symbol,
        "bid_amount" => Rpc.format_units(snapshot.bid.amount, decimals),
        "bid_amount_atomic" => Integer.to_string(snapshot.bid.amount),
        "max_price_q96" => Integer.to_string(snapshot.bid.max_price_q96),
        "final_clearing_price_q96" => Integer.to_string(snapshot.final_clearing_price_q96),
        "graduated" => snapshot.graduated?,
        "end_block" => Integer.to_string(snapshot.end_block),
        "claim_block" => Integer.to_string(snapshot.claim_block),
        "currency_refunded" =>
          exit && Rpc.format_units(exit_int(exit, "currency_refunded"), decimals),
        "tokens_filled" =>
          exit && Rpc.format_units(exit_int(exit, "tokens_filled"), @new_decimals),
        "tokens_claimed" =>
          claim && Rpc.format_units(exit_int(claim, "tokens_claimed"), @new_decimals),
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "steps" => steps
      }
    )
    |> stored()
  end

  defp exit_int(step, key), do: step |> Map.fetch!(key) |> String.to_integer()

  defp risk_copy(exit, claim, auction) do
    parts =
      Enum.reject(
        [
          exit && "returns your unspent #{auction.quote_token_symbol} from this auction",
          claim && "delivers your #{auction.token_symbol || "launch"} tokens"
        ],
        &is_nil/1
      )

    "Your wallet signs a transaction that #{Enum.join(parts, ", then one that ")} on a local Base fork. Test assets have no mainnet value."
  end

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Positions

  defp owned_position(bid_position_id, actor) do
    with {:ok, uuid} <- cast_uuid(bid_position_id),
         {:ok, position} <-
           Bid
           |> Ash.Query.for_read(:mine, %{}, domain: @domain, actor: actor)
           |> Ash.Query.filter(id == ^uuid)
           |> Ash.read_one(domain: @domain, actor: actor) do
      if position, do: {:ok, position}, else: unavailable(:not_your_bid)
    else
      {:error, _reason} -> unavailable(:not_your_bid)
    end
  end

  defp cast_uuid(value) do
    case Ash.Type.UUID.cast_input(value, []) do
      {:ok, uuid} when not is_nil(uuid) -> {:ok, uuid}
      _invalid -> unavailable(:not_your_bid)
    end
  end

  defp position_signer(%{owner_address: owner}, signer) do
    if Address.equal?(owner, signer), do: :ok, else: unavailable(:not_your_bid)
  end

  defp onchain_bid_id(%{onchain_bid_id: id, auction_address: address})
       when is_binary(id) and is_binary(address),
       do: {:ok, String.to_integer(id)}

  defp onchain_bid_id(_position), do: unavailable(:position_not_on_chain)

  defp owner_matches(%{bid: %{owner: owner}}, signer) do
    if Address.equal?(owner, signer), do: :ok, else: unavailable(:not_your_bid)
  end

  # Chain snapshot

  defp snapshot(auction_address, bid_id, signer) do
    case chain_client().snapshot(%{auction: auction_address, bid_id: bid_id, signer: signer}) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp chain_client,
    do:
      Application.get_env(
        :autolaunch,
        :autolaunch_bid_settlement_chain_client,
        LabBidSettlementChainClient
      )

  # Operations

  defp open(lease, position, signer, envelope) do
    transact(lease, fn account ->
      with :ok <- signer_matches(account, signer),
           :ok <- release_undispatched(position.id) do
        BidSettlementOperation
        |> Ash.Changeset.for_create(
          :prepare,
          %{
            action_id: envelope["action_id"],
            envelope: envelope,
            signer: signer,
            step: first_step(envelope),
            human_account_id: account.id,
            bid_position_id: position.id
          },
          domain: @domain,
          actor: @actor
        )
        |> Ash.create(actor: @actor)
      end
    end)
  end

  defp first_step(envelope),
    do: envelope["arguments"]["steps"] |> hd() |> Map.fetch!("step") |> String.to_existing_atom()

  # A new review of the same position always ends whatever is open as replaced.
  defp release_undispatched(bid_position_id) do
    case open_row(bid_position_id, true) do
      {:ok, nil} -> :ok
      {:ok, %{state: :prepared} = open} -> released(update(open, :cancel, %{reason: @replaced}))
      {:ok, open} -> released(update(open, :close_submission_unknown, %{reason: @replaced}))
      {:error, reason} -> {:error, reason}
    end
  end

  defp released({:ok, _closed}), do: :ok
  defp released(error), do: error

  defp claiming(signer, candidate) do
    fn account, operation ->
      with :ok <- same_signer(operation, signer),
           :ok <- signer_matches(account, operation.signer),
           :ok <- unchanged(operation, candidate) do
        if valid_envelope?(operation),
          do: update(operation, :claim_dispatch, %{}),
          else: update(operation, :cancel, %{reason: "the reviewed network changed"})
      end
    end
  end

  defp unchanged(operation, candidate) do
    if identity(operation) == identity(candidate),
      do: :ok,
      else: unavailable(:settlement_step_moved)
  end

  defp same_signer(%{signer: signer}, signer), do: :ok
  defp same_signer(_operation, _other), do: unavailable(:wrong_signer)

  defp valid_envelope?(operation) do
    Envelope.valid?(operation.envelope,
      resource: @resource,
      action: @action,
      signer: operation.signer,
      to: operation.envelope["to"],
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    ) and
      Lab.binding_matches?(
        operation.envelope["metadata"]["lab"],
        LabBidSettlementChainClient.binding_keys()
      )
  end

  defp transition(action, nil), do: fn _account, operation -> update(operation, action, %{}) end

  defp transition(action, reason),
    do: fn _account, operation -> update(operation, action, %{reason: reason}) end

  defp bind(operation, step, hash) do
    attribute = Map.fetch!(@hash_attributes, step)

    case Map.fetch!(operation, attribute) do
      ^hash -> {:ok, operation}
      nil -> bind_step(operation, step, attribute, hash)
      _different -> unavailable(:submitted_hash_conflict)
    end
  end

  defp bind_step(%{step: step} = operation, step, attribute, hash),
    do: update(operation, bind_action(operation), %{attribute => hash})

  defp bind_step(_operation, _step, _attribute, _hash), do: unavailable(:submitted_step_mismatch)

  defp bind_action(%{terminal_at: nil}), do: :bind_hash
  defp bind_action(_terminal), do: :attach_late_hash

  defp read_chain(%{state: :submitted} = candidate) do
    hash = step_hash(candidate, candidate.step)

    case chain_client().verify(candidate.envelope, candidate.step, hash) do
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      result -> result
    end
  end

  defp read_chain(_settled), do: {:ok, nil}

  defp settle(candidate, outcome) do
    fn _account, operation ->
      if identity(operation) == identity(candidate),
        do: record(operation, outcome),
        else: {:ok, operation}
    end
  end

  defp identity(operation), do: Map.take(operation, @identity)

  # A verified exit projects the position as returned and, when a claim step
  # follows, makes it sendable; a verified claim projects it as claimed.
  defp record(operation, %{outcome: :confirmed} = outcome) do
    result = merged(operation, outcome)

    with :ok <- LabProjection.project_settlement(operation, operation.step, outcome[:result]) do
      if operation.step == :exit and next_step?(operation),
        do: update(operation, :advance, %{result: result}),
        else: update(operation, :confirm, %{result: result})
    end
  end

  defp record(operation, %{outcome: :reverted}),
    do: update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: update(operation, :record_unverified, %{reason: @contradicted})

  defp record(operation, _unresolved), do: {:ok, operation}

  defp next_step?(operation), do: Enum.any?(steps(operation), &(&1["step"] == "claim"))

  defp merged(%{result: result}, outcome), do: Map.merge(result || %{}, outcome[:result] || %{})

  defp expire_lapsed(%{state: :prepared, envelope: %{"expires_at" => expires_at}} = operation) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)

    if DateTime.compare(expires_at, Envelope.current_time()) != :gt,
      do: update(operation, :expire, %{reason: @lapsed}),
      else: {:ok, operation}
  end

  defp expire_lapsed(operation), do: {:ok, operation}

  # Durable write plumbing

  defp write(action_id, opts, transition) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         do: transact(lease, &locked(&1, action_id, transition))
  end

  defp locked(account, action_id, transition) do
    with {:ok, operation} <- operation(account.id, action_id, true),
         {:ok, operation} <- expire_lapsed(operation),
         {:ok, operation} <- resume(operation, account, transition),
         do: {:ok, %{operation: presented(operation)}}
  end

  defp resume(%{state: :expired} = operation, _account, _transition), do: {:ok, operation}
  defp resume(operation, account, transition), do: transition.(account, operation)

  defp transact(%{lineage: lineage, account_id: account_id}, callback) do
    case SessionAuthority.transact_lease(lineage, account_id, callback) do
      {:error, :stale_authority} -> unavailable(:session_unavailable)
      result -> result
    end
  end

  defp operation(account_id, action_id, lock?) do
    BidSettlementOperation
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(action_id == ^action_id and human_account_id == ^account_id)
    |> locked_query(lock?)
    |> Ash.read_one(domain: @domain, actor: @actor)
    |> case do
      {:ok, nil} -> unavailable(:settlement_operation_not_found)
      other -> other
    end
  end

  defp open_row(bid_position_id, lock?) do
    BidSettlementOperation
    |> Ash.Query.for_read(:open, %{bid_position_id: bid_position_id},
      domain: @domain,
      actor: @actor
    )
    |> locked_query(lock?)
    |> Ash.read_one(domain: @domain)
  end

  defp locked_query(query, true), do: Ash.Query.lock(query, :for_update)
  defp locked_query(query, false), do: query

  defp update(operation, action, input) do
    operation
    |> Ash.Changeset.for_update(action, input, domain: @domain, actor: @actor)
    |> Ash.update(actor: @actor)
  end

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

  defp current_wallet(address, opts) do
    with {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         :ok <-
           lease.lineage
           |> SessionAuthority.leased_account(lease.account_id)
           |> signer_matches(signer),
         do: {:ok, signer}
  end

  defp signer_matches(nil, _signer), do: unavailable(:session_unavailable)

  defp signer_matches(%{wallet_addresses: wallets}, signer) do
    if Enum.any?(wallets || [], &Address.equal?(&1, signer)),
      do: :ok,
      else: unavailable(:wrong_signer)
  end

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

  defp unavailable(reason),
    do:
      {:error,
       Ash.Error.Invalid.Unavailable.exception(resource: BidSettlementOperation, reason: reason)}
end
