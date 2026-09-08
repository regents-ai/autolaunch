defmodule Autolaunch.SubjectWalletActions do
  @moduledoc """
  The one boundary between a subject's wallet and Base.

  Preparation reads Base once, proves the stored splitter and canonical receiver
  really are this launch's own, and writes the whole reviewed sequence as a
  single immutable envelope. Every durable write after that runs inside
  `SessionAuthority.transact_lease/3` as the outermost transaction, against the
  account that callback locked, so a claim, a bound hash or a settled outcome
  cannot outlive a concurrent logout.

  The wallet Privy has selected drives everything. Its address arrives as
  untrusted browser input and is proved against the account the mounted lease
  resolves to before any private fact is read; there is no fall back to a stored
  primary wallet or to the first linked one.

  Provider reads always happen before the lease transaction; only the row write
  happens inside it, and the row is taken `FOR UPDATE` first, so two sockets
  racing the same step serialize and exactly one of them wins.
  """

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc, SubjectAbi}
  alias Autolaunch.{SubjectWalletChainClient, SubjectWalletOperations}

  @chain_id 8453
  @resource "autolaunch_subject_wallet"
  @zero "0x0000000000000000000000000000000000000000"

  # The exact 2% every recognized inflow floors once, and the fixed denominator
  # the post-skim net is divided by: the complete SUBJECT supply every authentic
  # launch mints. Current stakers collectively receive the fraction of the net
  # their stake covers of that whole supply; the treasury receives the rest.
  @protocol_share_bps 200
  @bps_denominator 10_000
  @subject_total_supply 100_000_000_000 * Integer.pow(10, 18)

  @kinds [:stake, :unstake, :claim, :claim_all, :pay, :sweep, :set_note]
  @splitter_kinds [:stake, :unstake, :claim, :claim_all]
  @receiver_kinds [:pay, :sweep, :set_note]
  # The two actions that recognize an inflow, and so divide one.
  @inflow_kinds [:pay, :sweep]
  @assets [:subject, :usdc, :regent]

  @contract_name %{splitter: "SubjectSplitterV1", receiver: "PaymentReceiverV1"}

  @action_name %{
    stake: "subject_stake",
    unstake: "subject_unstake",
    claim: "subject_claim",
    claim_all: "subject_claim_all",
    pay: "subject_pay",
    sweep: "subject_sweep",
    set_note: "subject_set_note"
  }

  @risk %{
    stake:
      "Your wallet stakes this SUBJECT into the launch's revenue split. It counts straight away, and you can take it back out from the next block onwards.",
    unstake: "Your wallet takes this staked SUBJECT back out of the launch's revenue split.",
    claim: "Your wallet collects the revenue this launch has already set aside for it.",
    claim_all: "Your wallet collects every asset this launch has already set aside for it.",
    pay: "Your wallet pays this amount into the launch's revenue split.",
    sweep:
      "Your wallet pays the gas to route a balance already sitting at this address into the launch's revenue split. Nothing is sent to your wallet.",
    set_note: "Your wallet sets the short label this address shows on its payments."
  }

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed action expired before it was sent"
  @unresolved "account started a new action while this one was unresolved"
  @reverted "verified revert on Base"
  @contradicted "canonical receipt contradicts the reviewed action"

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  # Everything a Base read was answered about. A settlement applies only to a row
  # still carrying all of it.
  @identity [:state, :step, :envelope, :approval_transaction_hash, :action_transaction_hash]

  @doc """
  What the wallet Privy has selected may actually do on this subject.

  The reported address is untrusted: it is proved against the account the mounted
  lease resolves to before any private fact is read, so a wallet the account does
  not hold is refused rather than answered about.
  """
  @spec wallet_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(subject_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, subject} <- stakeable(subject_id),
         {:ok, snapshot} <- snapshot(subject, signer, nil, nil) do
      {:ok, view(subject, signer, snapshot)}
    end
  end

  @doc """
  Reviews one action: one snapshot, one immutable envelope, one durable operation.

  The sequence carries only the transactions this wallet still needs — an exact
  token approval when one is missing, then the single C1 call it enables.
  """
  @spec prepare(String.t(), String.t(), atom(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(subject_id, address, kind, params, opts) when kind in @kinds do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, lease} <- lease(opts),
         {:ok, subject} <- actionable(subject_id, kind),
         {:ok, asset} <- selected_asset(kind, params),
         {:ok, snapshot} <- snapshot(subject, signer, kind, asset),
         {:ok, review} <- reviewed(subject, signer, kind, asset, params, snapshot),
         {:ok, operation} <- open(lease, subject, signer, kind, review) do
      {:ok, %{operation: operation}}
    end
  end

  def prepare(_subject_id, _address, _kind, _params, _opts), do: unavailable(:unknown_action)

  @doc """
  Claims the current step's dispatch. Only this winner may open the wallet.

  The locked account, the signer the stored envelope pinned and the address the
  browser is offering right now all have to agree, inside the transaction that
  takes the row, so a wallet the account no longer holds cannot be handed a
  dispatch by a check that passed a moment earlier.
  """
  @spec claim_dispatch(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def claim_dispatch(subject_id, action_id, address, opts) do
    with {:ok, signer} <- normalize(address),
         do: write(subject_id, action_id, opts, claiming(signer))
  end

  # The wallet the browser is offering right now, the signer this review pinned,
  # and the account the lease locked all have to name the same wallet, inside the
  # one transaction that takes the row.
  defp claiming(signer) do
    fn account, operation ->
      with :ok <- same_signer(operation, signer),
           :ok <- SubjectWalletOperations.signer_matches(account, operation.signer),
           do: SubjectWalletOperations.update(operation, :claim_dispatch)
    end
  end

  @doc "Binds the first valid hash for the step the browser was actually sent."
  @spec bind_hash(String.t(), String.t(), atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def bind_hash(subject_id, action_id, step, hash, opts) when step in [:approval, :action] do
    with {:ok, hash} <- canonical_hash(hash) do
      write(subject_id, action_id, opts, fn _account, operation ->
        SubjectWalletOperations.bind(operation, step, hash)
      end)
    end
  end

  def bind_hash(_subject_id, _action_id, _step, _hash, _opts), do: unavailable(:unknown_step)

  @doc """
  Reads the exact bound hash and records whatever it truthfully settles as.

  Base is read from the candidate row alone, before any lease transaction opens,
  so no provider call ever happens under a row lock. The locked row then has to
  still be that same candidate — same state, step, bound hashes and reviewed
  envelope — or the outcome is dropped rather than applied to a step it never
  described.

  A hash the chain has not resolved writes nothing at all, so the same hash can
  be read again later; an approval advances the sequence only once its own
  allowance really holds, and only this action's own event confirms it.
  """
  @spec verify(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(subject_id, action_id, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, subject_id, action_id, false),
         {:ok, outcome} <- read_chain(candidate) do
      transact(lease, fn account ->
        locked(account, subject_id, action_id, settle(candidate, outcome))
      end)
    end
  end

  @spec cancel(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(subject_id, action_id, opts),
    do: write(subject_id, action_id, opts, transition(:cancel, @withdrawn))

  @spec close_not_sent(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close_not_sent(subject_id, action_id, opts),
    do: write(subject_id, action_id, opts, transition(:close_not_sent, @rejected))

  @spec release_unstarted(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def release_unstarted(subject_id, action_id, opts),
    do: write(subject_id, action_id, opts, transition(:release_unstarted, nil))

  @doc """
  Ends an action whose claimed step never resolved, at the account's request.

  Its calldata is never resent and its bound hashes stay exactly where they are.
  The row remains for the canonical projector; only this account's open slot for
  this subject is released.
  """
  @spec start_new(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_new(subject_id, action_id, opts),
    do:
      write(subject_id, action_id, opts, fn _account, operation ->
        action = if operation.state == :prepared, do: :cancel, else: :close_submission_unknown
        SubjectWalletOperations.update(operation, action, %{reason: @unresolved})
      end)

  @doc """
  The account's open operation for this subject, recovered under its current lease.

  Recovery reads private facts, so it requires the same current lease every other
  path does: the lease has to resolve an account right now, the acting human has
  to be that account, and the row is read by the account the lease resolved
  rather than by anything the caller named. Nothing is written. A missing,
  revoked or account-mismatched lease is refused without naming a single fact of
  whatever operation may exist.
  """
  @spec open_operation(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_operation(subject_id, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, operation} <- SubjectWalletOperations.open(account.id, subject_id, false),
         do: {:ok, %{operation: presented(operation)}}
  end

  @doc "The presenter's whole view of one operation. Everything else stays server-side."
  @spec presented(Ash.Resource.record() | nil) :: map() | nil
  def presented(nil), do: nil

  def presented(operation) do
    Map.take(operation, [
      :action_id,
      :subject_id,
      :kind,
      :state,
      :step,
      :signer,
      :envelope,
      :result,
      :approval_transaction_hash,
      :action_transaction_hash,
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :subject)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  @spec steps(map()) :: [map()]
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  @doc """
  The hash bound for one named step of an operation, or `nil`.

  The two reviewed steps are named exactly, so a value that is neither has no
  hash rather than becoming an atom.
  """
  @spec step_hash(map(), String.t() | atom()) :: String.t() | nil
  def step_hash(operation, step) when step in [:approval, "approval"],
    do: SubjectWalletOperations.hash(operation, :approval)

  def step_hash(operation, step) when step in [:action, "action"],
    do: SubjectWalletOperations.hash(operation, :action)

  def step_hash(_operation, _unknown), do: nil

  @doc "The exact decimal rendering of an atomic amount of one bound asset."
  @spec units(non_neg_integer() | String.t(), atom()) :: String.t()
  def units(amount, asset) when is_binary(amount),
    do: amount |> String.to_integer() |> units(asset)

  def units(amount, asset), do: Rpc.format_units(amount, SubjectAbi.decimals(asset))

  @doc """
  The amount a confirmed action's own event proves moved, or `nil`.

  Two of the seven learn an amount only from the chain. A claim reads the
  reviewed token's entry in `result["claimed"]`, where an absent entry is the
  truthful zero of a canonical success that had nothing to collect; a sweep reads
  the `result["gross"]` its routing event reported. Both render through the
  reviewed decimals the envelope pinned.

  Everything else — another action, a row that has not confirmed, and a stored
  result that carries no whole atomic amount — has no verified amount, so the
  reviewed estimate is what still stands.
  """
  @spec verified_amount(map()) :: String.t() | nil
  def verified_amount(%{state: :confirmed, kind: :claim} = operation),
    do: reviewed_units(collected(operation), operation)

  def verified_amount(%{state: :confirmed, kind: :sweep} = operation),
    do: reviewed_units(operation.result["gross"], operation)

  def verified_amount(_operation), do: nil

  # A canonical claim records only its own reviewed token, so an absent entry is
  # a success that collected nothing rather than an unknown amount.
  defp collected(%{result: %{"claimed" => claimed}} = operation) when is_map(claimed),
    do: Map.get(claimed, argument(operation, "token"), "0")

  defp collected(_operation), do: nil

  # An atomic amount is exactly digits against the decimals this review pinned.
  # Anything else is not an amount, so nothing is rendered as one.
  defp reviewed_units(amount, operation) when is_binary(amount) do
    decimals = argument(operation, "decimals")

    if String.match?(amount, ~r/^\d+$/) and is_integer(decimals) and decimals >= 0,
      do: Rpc.format_units(String.to_integer(amount), decimals),
      else: nil
  end

  defp reviewed_units(_amount, _operation), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  # Reviews

  defp reviewed(subject, signer, kind, asset, params, snapshot) do
    with {:ok, plan} <- planned(kind, asset, params, snapshot, signer) do
      {:ok, stored(envelope(subject, signer, kind, asset, plan, snapshot))}
    end
  end

  # One stored shape: the envelope is written, read and rendered exactly as the
  # confirmation token signed it.
  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Every rule the plan fixes for one action, answered from the one snapshot.
  defp planned(:stake, asset, params, snapshot, _signer) do
    with :ok <- stakeable_asset(asset),
         {:ok, amount} <- positive_amount(params, asset),
         :ok <- at_most(amount, balance(snapshot, asset), :amount_above_balance) do
      {:ok,
       %{
         amount: amount,
         spender: snapshot.splitter.address,
         data: SubjectAbi.encode_stake(amount)
       }}
    end
  end

  defp planned(:unstake, asset, params, snapshot, _signer) do
    with :ok <- stakeable_asset(asset),
         {:ok, amount} <- positive_amount(params, asset),
         :ok <- at_most(amount, snapshot.splitter.staked_of, :amount_above_stake) do
      {:ok, %{amount: amount, data: SubjectAbi.encode_unstake(amount)}}
    end
  end

  defp planned(:claim, asset, _params, snapshot, _signer) do
    address = asset_address(snapshot, asset)

    if claimable(snapshot, asset) > 0,
      do: {:ok, %{amount: claimable(snapshot, asset), data: SubjectAbi.encode_claim(address)}},
      else: unavailable(:nothing_claimable)
  end

  defp planned(:claim_all, _asset, _params, snapshot, _signer) do
    if Enum.any?(@assets, &(claimable(snapshot, &1) > 0)),
      do: {:ok, %{data: SubjectAbi.encode_claim_all()}},
      else: unavailable(:nothing_claimable)
  end

  defp planned(:pay, asset, params, snapshot, _signer) do
    with {:ok, amount} <- positive_amount(params, asset),
         :ok <- at_most(amount, balance(snapshot, asset), :amount_above_balance) do
      reference = payment_reference()

      {:ok,
       %{
         amount: amount,
         spender: snapshot.receiver.address,
         payment_reference: reference,
         data: SubjectAbi.encode_pay(asset_address(snapshot, asset), amount, reference)
       }}
    end
  end

  # The receiver's own current balance is what a sweep routes, so it is reviewed
  # rather than chosen, and the event supplies the amount that actually moved.
  defp planned(:sweep, asset, _params, snapshot, _signer) do
    held = snapshot.receiver.balances[asset]

    if held > 0 do
      reference = payment_reference()

      {:ok,
       %{
         amount: held,
         payment_reference: reference,
         data: SubjectAbi.encode_sweep(asset_address(snapshot, asset), reference)
       }}
    else
      unavailable(:nothing_to_sweep)
    end
  end

  defp planned(:set_note, _asset, params, snapshot, signer) do
    with :ok <- note_editor(snapshot, signer),
         {:ok, note} <- note(params) do
      {:ok, %{note: note, data: SubjectAbi.encode_set_receiver_note(note)}}
    end
  end

  defp envelope(subject, signer, kind, asset, plan, snapshot) do
    target = target(kind, snapshot)

    steps =
      approval_step(plan, snapshot, asset) ++
        [%{"step" => "action", "to" => target, "data" => plan.data}]

    Envelope.new(Map.fetch!(@action_name, kind), signer, plan.data,
      to: target,
      resource: @resource,
      contract_name: Map.fetch!(@contract_name, contract(kind)),
      risk_copy: Map.fetch!(@risk, kind),
      arguments: arguments(subject, kind, asset, plan, snapshot, steps)
    )
  end

  defp arguments(subject, kind, asset, plan, snapshot, steps) do
    %{
      "subject_id" => subject.subject_id,
      "kind" => Atom.to_string(kind),
      "splitter" => snapshot.splitter.address,
      "receiver" => receiver_address(snapshot),
      "treasury" => snapshot.splitter.treasury,
      "asset" => asset && Atom.to_string(asset),
      "token" => asset && asset_address(snapshot, asset),
      "symbol" => asset && symbol(asset),
      "decimals" => asset && SubjectAbi.decimals(asset),
      "amount_atomic" => plan[:amount] && Integer.to_string(plan.amount),
      "amount" => plan[:amount] && units(plan.amount, asset),
      "payment_reference" => plan[:payment_reference],
      "note" => plan[:note],
      "total_staked" => Integer.to_string(snapshot.splitter.total_staked),
      "protocol_share_bps" => @protocol_share_bps,
      "allocation" => allocation(kind, plan, snapshot),
      "bound_tokens" => Map.new(@assets, &{Atom.to_string(&1), asset_address(snapshot, &1)}),
      "steps" => steps
    }
  end

  # Only the approval this wallet still needs. An allowance that already covers
  # the reviewed amount is spent exactly as it stands.
  defp approval_step(%{spender: spender, amount: amount}, snapshot, asset)
       when is_binary(spender) do
    if snapshot.allowance >= amount do
      []
    else
      [
        %{
          "step" => "approval",
          "to" => asset_address(snapshot, asset),
          "data" => Abi.encode_erc20("approve", [spender, amount]),
          "amount" => Integer.to_string(amount),
          "spender" => spender
        }
      ]
    end
  end

  defp approval_step(_plan, _snapshot, _asset), do: []

  # The exact integer division one recognized inflow makes, floored twice and in
  # atomic units of the reviewed asset: the 2% skim, then the staker allocation
  # the stake covers of the complete SUBJECT supply, then the exact remainder to
  # the treasury. Nothing here is a percentage, an estimate, or a chain read.
  defp allocation(kind, %{amount: gross}, %{splitter: %{total_staked: staked}})
       when kind in @inflow_kinds do
    skim = div(gross * @protocol_share_bps, @bps_denominator)
    net = gross - skim
    stakers = div(net * staked, @subject_total_supply)

    Map.new(
      [gross: gross, skim: skim, net: net, stakers: stakers, treasury: net - stakers],
      fn {part, amount} -> {Atom.to_string(part), Integer.to_string(amount)} end
    )
  end

  defp allocation(_kind, _plan, _snapshot), do: nil

  defp target(kind, snapshot) when kind in @splitter_kinds, do: snapshot.splitter.address
  defp target(_receiver_kind, snapshot), do: snapshot.receiver.address

  defp contract(kind) when kind in @splitter_kinds, do: :splitter
  defp contract(_receiver_kind), do: :receiver

  defp receiver_address(%{receiver: %{address: address}}), do: address
  defp receiver_address(_none), do: nil

  def press_evidence(operation) do
    if Envelope.valid?(operation.envelope, resource: @resource),
      do: :ok,
      else: unavailable(:subject_wallet_preparation_unavailable)
  end

  # Operations

  defp open(lease, subject, signer, kind, envelope) do
    transact(lease, fn account ->
      with :ok <- SubjectWalletOperations.signer_matches(account, signer),
           :ok <- release_undispatched(account.id, subject.subject_id),
           {:ok, operation} <-
             SubjectWalletOperations.create(account, %{
               action_id: envelope["action_id"],
               subject_id: subject.subject_id,
               kind: kind,
               envelope: envelope,
               signer: signer,
               step:
                 envelope["arguments"]["steps"]
                 |> hd()
                 |> Map.fetch!("step")
                 |> String.to_existing_atom()
             }),
           do: {:ok, presented(operation)}
    end)
  end

  # A new prepare always cancels whatever is open as :replaced and proceeds.
  # A different subject is completely independent.
  defp release_undispatched(account_id, subject_id) do
    case SubjectWalletOperations.open(account_id, subject_id, true) do
      {:ok, nil} ->
        :ok

      {:ok, open} ->
        replace_open(open)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_open(%{state: :prepared} = open) do
    with {:ok, _cancelled} <-
           SubjectWalletOperations.update(open, :cancel, %{reason: @replaced}),
         do: :ok
  end

  defp replace_open(open) do
    with {:ok, _cancelled} <-
           SubjectWalletOperations.update(open, :close_submission_unknown, %{reason: @replaced}),
         do: :ok
  end

  defp transition(action, nil),
    do: fn _account, operation -> SubjectWalletOperations.update(operation, action) end

  defp transition(action, reason),
    do: fn _account, operation ->
      SubjectWalletOperations.update(operation, action, %{reason: reason})
    end

  # The one Base read a settlement makes, with no transaction and no lock open.
  # A candidate with nothing sent to read about asks nothing.
  defp read_chain(%{state: :submitted} = candidate) do
    hash = SubjectWalletOperations.hash(candidate, candidate.step)

    case SubjectWalletChainClient.module().verify(candidate.envelope, candidate.step, hash) do
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

  defp record(%{step: :approval} = operation, %{outcome: :confirmed}),
    do: SubjectWalletOperations.update(operation, :advance)

  defp record(operation, %{outcome: :confirmed} = result),
    do: SubjectWalletOperations.update(operation, :confirm, %{result: result[:result] || %{}})

  defp record(operation, %{outcome: :reverted}),
    do: SubjectWalletOperations.update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: SubjectWalletOperations.update(operation, :record_unverified, %{reason: @contradicted})

  # A hash the chain has not resolved yet, and a candidate that had nothing to
  # read, both leave the row bound and readable again.
  defp record(operation, _unresolved), do: {:ok, operation}

  # The reviewed envelope lives ten minutes. Past that, no prepared step of it
  # can be spent, so the operation ends here — inside the locked transaction,
  # ahead of the transition — and a new review rereads current state.
  defp expire_lapsed(%{state: :prepared} = operation) do
    if expired?(operation),
      do: SubjectWalletOperations.update(operation, :expire, %{reason: @lapsed}),
      else: {:ok, operation}
  end

  defp expire_lapsed(operation), do: {:ok, operation}

  defp expired?(%{envelope: %{"expires_at" => expires_at}}) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
    DateTime.compare(expires_at, Envelope.current_time()) != :gt
  end

  # Durable write plumbing

  defp write(subject_id, action_id, opts, transition) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         do: transact(lease, &locked(&1, subject_id, action_id, transition))
  end

  defp locked(account, subject_id, action_id, transition) do
    with {:ok, operation} <- operation(account.id, subject_id, action_id, true),
         {:ok, operation} <- expire_lapsed(operation),
         {:ok, operation} <- resume(operation, account, transition),
         do: {:ok, %{operation: presented(operation)}}
  end

  # An operation the lapse just ended is itself the outcome, and it commits:
  # nothing further is asked of bytes that can no longer be spent.
  defp resume(%{state: :expired} = operation, _account, _transition), do: {:ok, operation}
  defp resume(operation, account, transition), do: transition.(account, operation)

  defp transact(lease, callback), do: SubjectWalletOperations.transact(lease, callback)

  defp operation(account_id, subject_id, action_id, lock?),
    do: SubjectWalletOperations.fetch(account_id, subject_id, action_id, lock?)

  # A review is prepared for one signer, and only that wallet may dispatch it.
  defp same_signer(%{signer: signer}, signer), do: :ok
  defp same_signer(_operation, _other), do: unavailable(:wrong_signer)

  # Chain snapshot

  defp snapshot(subject, signer, kind, asset) do
    request = %{
      splitter: subject.splitter_address,
      receiver: receiver_request(subject),
      signer: signer,
      token: asset && subject_asset_address(subject, asset),
      spender: spender_request(kind, subject)
    }

    case SubjectWalletChainClient.module().snapshot(request) do
      {:ok, snapshot} -> snapshot |> put_addresses(subject) |> proved(subject, kind)
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # A receiver is read whenever the subject has a projected one, so the page can
  # show the note and the receiver's own balances before any action is chosen.
  defp receiver_request(%{canonical_receiver_address: address}) when is_binary(address),
    do: address

  defp receiver_request(_subject), do: nil

  defp spender_request(:stake, subject), do: subject.splitter_address
  defp spender_request(:pay, subject), do: subject.canonical_receiver_address
  defp spender_request(_kind, _subject), do: nil

  # Every binding the review depends on, proved against the pinned product
  # authority before a durable review can exist. The receiver additionally has to
  # be canonical: zero referral, and a treasury that is both its beneficiary and
  # its note editor, which is the whole of the economics the page promises.
  defp proved(snapshot, subject, kind) do
    with :ok <-
           bound(snapshot.splitter.subject, subject.token_address, :splitter_subject_mismatch),
         :ok <- bound(snapshot.splitter.usdc, Abi.usdc_address(), :splitter_usdc_mismatch),
         :ok <-
           bound(snapshot.splitter.regent, Abi.regent_address(), :splitter_regent_mismatch),
         :ok <-
           bound(
             snapshot.splitter.treasury,
             subject.treasury_address,
             :splitter_treasury_mismatch
           ),
         :ok <- canonical_receiver(snapshot, subject, kind) do
      {:ok, snapshot}
    end
  end

  defp canonical_receiver(%{receiver: nil}, _subject, kind) when kind in @receiver_kinds,
    do: unavailable(:canonical_receiver_unavailable)

  defp canonical_receiver(%{receiver: nil}, _subject, _kind), do: :ok

  defp canonical_receiver(%{receiver: receiver, splitter: splitter}, subject, _kind) do
    with :ok <- bound(receiver.splitter, splitter.address, :receiver_splitter_mismatch),
         :ok <- bound(receiver.subject, subject.token_address, :receiver_subject_mismatch),
         :ok <- bound(receiver.usdc, Abi.usdc_address(), :receiver_usdc_mismatch),
         :ok <- bound(receiver.regent, Abi.regent_address(), :receiver_regent_mismatch),
         :ok <- bound(receiver.treasury, splitter.treasury, :receiver_treasury_mismatch),
         :ok <- bound(receiver.beneficiary, splitter.treasury, :receiver_not_canonical),
         :ok <- bound(receiver.note_editor, splitter.treasury, :receiver_not_canonical),
         do: zero_referral(receiver)
  end

  defp zero_referral(%{referral_bps: 0}), do: :ok
  defp zero_referral(_referring), do: unavailable(:receiver_not_canonical)

  defp bound(actual, expected, reason) do
    if is_binary(expected) and Address.equal?(actual, expected),
      do: :ok,
      else: unavailable(reason)
  end

  defp put_addresses(snapshot, subject) do
    snapshot
    |> put_in([:splitter, :address], normalized!(subject.splitter_address))
    |> put_receiver_address(subject)
  end

  defp put_receiver_address(%{receiver: nil} = snapshot, _subject), do: snapshot

  defp put_receiver_address(snapshot, subject),
    do: put_in(snapshot, [:receiver, :address], normalized!(subject.canonical_receiver_address))

  # Stored subjects

  defp stakeable(subject_id) do
    with {:ok, subject} <- stored_subject(subject_id),
         :ok <- base_chain(subject),
         :ok <- standard(subject.token_address, :subject_token_unavailable),
         :ok <- standard(subject.splitter_address, :subject_splitter_unavailable),
         :ok <- standard(subject.treasury_address, :subject_treasury_unavailable),
         do: {:ok, subject}
  end

  defp actionable(subject_id, kind) when kind in @receiver_kinds do
    with {:ok, subject} <- stakeable(subject_id),
         :ok <- standard(subject.canonical_receiver_address, :canonical_receiver_unavailable),
         do: {:ok, subject}
  end

  defp actionable(subject_id, _splitter_kind), do: stakeable(subject_id)

  defp stored_subject(subject_id) do
    case Autolaunch.get_public_subject(subject_id, actor: nil) do
      {:ok, nil} -> unavailable(:subject_not_found)
      {:ok, subject} -> {:ok, subject}
      {:error, _reason} -> unavailable(:subject_unavailable)
    end
  end

  defp base_chain(%{chain_id: @chain_id}), do: :ok
  defp base_chain(_other), do: unavailable(:subject_not_on_base)

  defp standard(address, reason) do
    case Address.normalize(address) do
      {:ok, @zero} -> unavailable(reason)
      {:ok, _address} -> :ok
      :error -> unavailable(reason)
    end
  end

  # Assets and amounts

  defp selected_asset(:stake, _params), do: {:ok, :subject}
  defp selected_asset(:unstake, _params), do: {:ok, :subject}
  defp selected_asset(:claim_all, _params), do: {:ok, nil}
  defp selected_asset(:set_note, _params), do: {:ok, nil}

  defp selected_asset(_kind, params) do
    case params["asset"] do
      "subject" -> {:ok, :subject}
      "usdc" -> {:ok, :usdc}
      "regent" -> {:ok, :regent}
      _unsupported -> unavailable(:unsupported_asset)
    end
  end

  defp stakeable_asset(:subject), do: :ok
  defp stakeable_asset(_other), do: unavailable(:unsupported_asset)

  defp positive_amount(params, asset), do: params |> Map.get("amount") |> atomic_amount(asset)

  @doc """
  The one amount language for a bound asset: exact digits, at most its decimals.

  The form validates against this, so the page never invites an amount that
  preparation would refuse.
  """
  @spec atomic_amount(term(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def atomic_amount(value, asset) when is_binary(value) do
    decimals = SubjectAbi.decimals(asset)
    value = String.trim(value)

    with true <- String.match?(value, ~r/^\d+(?:\.\d{1,#{decimals}})?$/),
         {decimal, ""} <- Decimal.parse(value),
         scaled <- Decimal.mult(decimal, Decimal.new(Integer.pow(10, decimals))),
         rounded <- Decimal.round(scaled, 0),
         :eq <- Decimal.compare(scaled, rounded),
         amount when amount > 0 <- Decimal.to_integer(rounded) do
      {:ok, amount}
    else
      _refused -> unavailable(:invalid_amount)
    end
  end

  def atomic_amount(_value, _asset), do: unavailable(:invalid_amount)

  defp at_most(amount, limit, _reason) when amount <= limit, do: :ok
  defp at_most(_amount, _limit, reason), do: unavailable(reason)

  defp note(params) do
    case params |> Map.get("note", "") |> SubjectAbi.encode_note() do
      {:ok, note} -> {:ok, note}
      :error -> unavailable(:invalid_note)
    end
  end

  defp note_editor(%{receiver: %{note_editor: editor}}, signer) do
    if Address.equal?(editor, signer), do: :ok, else: unavailable(:not_note_editor)
  end

  defp note_editor(_snapshot, _signer), do: unavailable(:canonical_receiver_unavailable)

  # Every operation carries its own cryptographically random reference, so two
  # payments of the same amount are never the same reviewed transaction.
  defp payment_reference,
    do: "0x" <> (32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp balance(snapshot, asset), do: snapshot.balances[asset]
  defp claimable(snapshot, asset), do: snapshot.splitter.claimable[asset]

  defp asset_address(snapshot, :subject), do: snapshot.splitter.subject
  defp asset_address(snapshot, :usdc), do: snapshot.splitter.usdc
  defp asset_address(snapshot, :regent), do: snapshot.splitter.regent

  defp subject_asset_address(subject, :subject), do: subject.token_address
  defp subject_asset_address(_subject, :usdc), do: Abi.usdc_address()
  defp subject_asset_address(_subject, :regent), do: Abi.regent_address()

  defp symbol(:subject), do: "SUBJECT"
  defp symbol(:usdc), do: "USDC"
  defp symbol(:regent), do: "REGENT"

  # The whole private answer for one wallet on one subject.
  defp view(subject, signer, snapshot) do
    %{
      signer: signer,
      subject_id: subject.subject_id,
      total_staked: units(snapshot.splitter.total_staked, :subject),
      staked: units(snapshot.splitter.staked_of, :subject),
      balances: Map.new(@assets, &{&1, units(balance(snapshot, &1), &1)}),
      claimable: Map.new(@assets, &{&1, units(claimable(snapshot, &1), &1)}),
      claimable_atomic: Map.new(@assets, &{&1, claimable(snapshot, &1)}),
      receiver: receiver_view(snapshot, signer)
    }
  end

  defp receiver_view(%{receiver: nil}, _signer), do: nil

  defp receiver_view(%{receiver: receiver}, signer) do
    %{
      address: receiver.address,
      note: SubjectAbi.note_display(receiver.note),
      note_editor?: Address.equal?(receiver.note_editor, signer),
      balances: Map.new(@assets, &{&1, units(receiver.balances[&1], &1)}),
      balances_atomic: Map.new(@assets, &{&1, receiver.balances[&1]})
    }
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
         :ok <- leased_wallet(lease, signer),
         do: {:ok, signer}
  end

  # The account the mounted lease resolves to right now. A lineage that has been
  # revoked, rebound or whose provider evidence has lapsed resolves to nothing.
  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp leased_wallet(lease, signer) do
    with {:ok, account} <- leased(lease),
         do: SubjectWalletOperations.signer_matches(account, signer)
  end

  # The lease and the acting human have to name one account, so a lease held for
  # another account answers about nothing.
  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

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

  defp normalized!(value) do
    {:ok, address} = Address.normalize(value)
    address
  end

  defp unavailable(reason), do: SubjectWalletOperations.unavailable(reason)
end
