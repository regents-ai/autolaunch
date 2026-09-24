defmodule Autolaunch.WalletAttempts do
  @moduledoc """
  Authority → account → review → attempt locking. Provider reads are outside locks.
  Review eligibility admits new presses only; outcomes of issued presses remain
  writable after expiry, withdrawal, replacement or another press's confirmation.
  No recovery path sends a transaction.
  """
  require Ash.Query

  alias Autolaunch.{
    BidOperation,
    BidSettlementOperation,
    LaunchOperation,
    SubjectWalletOperation,
    WalletAttempt
  }

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.Stocks.LaunchOperation, as: StocksLaunchOperation
  @system %System{}
  @kinds [:bid, :launch, :subject, :stocks_launch, :bid_settlement]

  def dispatch(kind, action_id, step, press_id, signer, opts)
      when kind in @kinds and is_binary(action_id) and (is_binary(step) or is_atom(step)) and
             is_binary(press_id) and is_binary(signer) do
    with {:ok, lease} <- authority(opts),
         {:ok, candidate} <- parent(kind, lease.account_id, action_id, false),
         {:ok, step} <- step(candidate, step),
         {:ok, _uuid} <- Ecto.UUID.cast(press_id),
         :ok <- eligible(candidate, step, signer),
         :ok <- actions(kind).press_evidence(%{candidate | step: step}) do
      transact(lease, &dispatch_locked(kind, &1, action_id, step, press_id, signer, candidate))
    else
      :error -> unavailable(:invalid_press)
      error -> error
    end
  end

  def dispatch(_, _, _, _, _, _), do: unavailable(:invalid_press)

  def report(kind, action_id, press_id, report, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts),
         do: transact(lease, &report_locked(kind, &1, action_id, press_id, report))
  end

  # A confirmed launch's listing notifications come out of the session's
  # transaction with its response and are sent only once it has committed, so
  # a page that rereads on them finds the new row; a rollback sends nothing.
  def verify(kind, action_id, press_id, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts),
         {:ok, candidate} <- parent(kind, lease.account_id, action_id, false),
         {:ok, attempt} <- issued(kind, candidate, press_id, false),
         {:ok, outcome} <- read_chain(kind, attempt),
         {:ok, {response, notifications}} <-
           transact(lease, &verify_locked(kind, &1, action_id, press_id, attempt, outcome)) do
      Ash.Notifier.notify(notifications)
      {:ok, response}
    end
  end

  # Under the account lock: the same operation, envelope and signer the
  # unlocked read admitted, then the press that already exists or a new one.
  defp dispatch_locked(kind, account, action_id, step, press_id, signer, candidate) do
    with {:ok, op} <- parent(kind, account.id, action_id, true),
         :ok <- eligible(op, step, signer),
         true <- op.envelope == candidate.envelope,
         true <- Address.equal?(account.wallet_address, signer),
         {:ok, existing} <- fetch(kind, op, press_id, true) do
      adopt(kind, op, step, press_id, existing)
    else
      false -> unavailable(:wrong_signer)
      error -> error
    end
  end

  defp adopt(kind, op, step, press_id, nil) do
    with {:ok, attempt} <- create(kind, op, step, press_id), do: response(kind, op, attempt, true)
  end

  defp adopt(
         kind,
         %{envelope: envelope} = op,
         step,
         _press_id,
         %{step: step, envelope: envelope} = attempt
       ),
       do: response(kind, op, attempt, false)

  defp adopt(_kind, _op, _step, _press_id, _attempt), do: unavailable(:press_identity_conflict)

  defp report_locked(kind, account, action_id, press_id, report) do
    with {:ok, op} <- parent(kind, account.id, action_id, true),
         {:ok, attempt} <- issued(kind, op, press_id, true),
         true <- step_matches?(report, attempt),
         {:ok, attempt} <- ingest(attempt, report) do
      response(kind, op, attempt, false)
    else
      false -> unavailable(:submitted_step_mismatch)
      error -> error
    end
  end

  defp step_matches?(report, attempt) do
    is_map(report) and
      (not Map.has_key?(report, "step") or report["step"] == Atom.to_string(attempt.step))
  end

  defp verify_locked(kind, account, action_id, press_id, attempt, outcome) do
    with {:ok, op} <- parent(kind, account.id, action_id, true),
         {:ok, current} <- issued(kind, op, press_id, true),
         {:ok, op, current, notifications} <- reconcile(kind, op, current, attempt, outcome),
         {:ok, response} <- response(kind, op, current, false),
         do: {:ok, {response, notifications}}
  end

  @hash_fields %{
    {:bid, :token_approval} => :token_approval_transaction_hash,
    {:bid, :permit2_approval} => :permit2_approval_transaction_hash,
    {:bid, :bid} => :bid_transaction_hash,
    {:bid, :usdc_approval} => :usdc_approval_transaction_hash,
    {:bid, :usdc_bid} => :usdc_bid_transaction_hash,
    {:launch, :launch} => :launch_transaction_hash,
    {:stocks_launch, :launch} => :launch_transaction_hash,
    {:bid_settlement, :exit} => :exit_transaction_hash,
    {:bid_settlement, :claim} => :claim_transaction_hash,
    {:subject, :action} => :action_transaction_hash
  }

  defp hash_field(_kind, :approval), do: :approval_transaction_hash
  defp hash_field(kind, step), do: Map.fetch!(@hash_fields, {kind, step})

  @doc """
  Whether a press for the review's current step is still with the wallet or
  awaiting its chain read. Such a review has not lapsed: its bytes may already
  be on chain, and only the chain read may settle it.
  """
  @spec in_flight?(atom(), Ash.Resource.record()) :: boolean()
  def in_flight?(kind, op) when kind in @kinds do
    query(kind, op)
    |> Ash.Query.filter(step == ^op.step and state in [:dispatched, :submitted])
    |> Ash.exists?(actor: @system)
  end

  def list(kind, action_id, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts),
         {:ok, op} <- parent(kind, lease.account_id, action_id, false),
         do: response(kind, op, nil, false)
  end

  defp authority(opts) do
    with %Human{human_account_id: id} <- opts[:actor],
         %{session_lease: %{lineage: lineage, account_id: ^id} = lease} <- opts[:context],
         account when not is_nil(account) <- SessionAuthority.leased_account(lineage, id) do
      {:ok, lease}
    else
      _ -> unavailable(:session_unavailable)
    end
  end

  defp transact(lease, fun) do
    case SessionAuthority.transact_lease(lease.lineage, lease.account_id, fun) do
      {:error, :stale_authority} -> unavailable(:session_unavailable)
      result -> result
    end
  end

  defp eligible(op, step, signer) do
    names = Enum.map(op.envelope["arguments"]["steps"], & &1["step"])
    requested = Enum.find_index(names, &(&1 == Atom.to_string(step)))
    current = Enum.find_index(names, &(&1 == Atom.to_string(op.step)))

    with true <- is_nil(op.terminal_at),
         true <- Address.equal?(op.signer, signer),
         true <- is_integer(requested) and is_integer(current) and requested <= current,
         {:ok, expiry, _} <- DateTime.from_iso8601(op.envelope["expires_at"]),
         :gt <- DateTime.compare(expiry, Envelope.current_time()) do
      :ok
    else
      _ -> unavailable(:review_not_sendable)
    end
  end

  defp step(op, value) do
    case Enum.find(op.envelope["arguments"]["steps"], &(&1["step"] == to_string(value))) do
      nil -> unavailable(:submitted_step_mismatch)
      item -> {:ok, String.to_existing_atom(item["step"])}
    end
  end

  defp parent(kind, account_id, action_id, lock?) do
    resource(kind)
    |> Ash.Query.filter(human_account_id == ^account_id and action_id == ^action_id)
    |> lock(lock?)
    |> Ash.read_one(actor: @system)
    |> case do
      {:ok, nil} -> unavailable(:operation_not_found)
      other -> other
    end
  end

  defp query(kind, op) do
    filter = [{foreign_key(kind), op.id}]
    Ash.Query.filter(WalletAttempt, ^filter)
  end

  defp fetch(kind, op, id, lock?) do
    query(kind, op) |> Ash.Query.filter(id == ^id) |> lock(lock?) |> Ash.read_one(actor: @system)
  end

  defp issued(kind, op, id, lock?) do
    case fetch(kind, op, id, lock?) do
      {:ok, nil} -> unavailable(:press_not_found)
      other -> other
    end
  end

  defp lock(query, true), do: Ash.Query.lock(query, :for_update)
  defp lock(query, false), do: query

  defp create(kind, op, step, id) do
    attrs = %{
      foreign_key(kind) => op.id,
      :id => id,
      :step => step,
      :envelope => op.envelope,
      :state => :dispatched,
      :transaction_hash => nil
    }

    WalletAttempt
    |> Ash.Changeset.for_create(:dispatch, attrs, actor: @system)
    |> Ash.create(actor: @system)
  end

  defp ingest(attempt, %{"transaction_hash" => hash}) do
    cond do
      not Rpc.valid_hash?(hash) ->
        unavailable(:invalid_hash)

      attempt.transaction_hash == String.downcase(hash) ->
        {:ok, attempt}

      not is_nil(attempt.transaction_hash) ->
        unavailable(:submitted_hash_conflict)

      true ->
        update(attempt, %{
          transaction_hash: String.downcase(hash),
          state: :submitted,
          resolved_at: nil
        })
    end
  end

  defp ingest(attempt, %{"outcome" => outcome})
       when outcome in ["not_sent", "not_started", "submission_unknown"] do
    cond do
      attempt.transaction_hash != nil -> {:ok, attempt}
      attempt.state in [:not_sent, :not_started] -> {:ok, attempt}
      true -> update(attempt, %{state: String.to_existing_atom(outcome)})
    end
  end

  defp ingest(_, _), do: unavailable(:invalid_report)

  defp read_chain(kind, %{state: :submitted} = attempt),
    do: chain_outcome(kind, attempt.envelope, attempt.step, attempt.transaction_hash)

  defp read_chain(_, _), do: {:ok, nil}

  defp chain_outcome(kind, envelope, step, hash) do
    module = client(kind)
    Code.ensure_loaded!(module)

    fun =
      if function_exported?(module, :verify_with_evidence, 3),
        do: :verify_with_evidence,
        else: :verify

    apply(module, fun, [envelope, step, hash])
  end

  # A transaction that is not this review's: another signer, target or
  # calldata, or a deployment the review was not made against.
  @not_this_review [:transaction_mismatch, :invalid_confirmation, :lab_config_changed]

  @doc """
  Lists one launch the chain shows from its transaction alone, with no browser
  report and nothing sent.

  The candidates are this site's launch reviews whose own signer is the
  launch's signer (a review is only sent from the wallet its account was
  signed in with at the time), so a creator who signs in with another wallet
  later still keeps the launch. The one whose envelope the transaction carried
  out exactly (signer, target, calldata, and the launchpad's own event and
  record) is the match: its press for that hash is recorded as confirmed,
  through the same projection a browser report reaches, and its account is the
  creator. Only that review's own presses are looked at: one the browser
  already reported for that hash is reused; otherwise an unreported press of
  the review takes the hash; otherwise the press is recorded here.

  Returns `{:listed, human_account_id}`, `{:unlisted, reason}` when no review
  of this site's accounts carried out the transaction, or `{:pending, reason}`
  while the chain cannot answer yet.
  """
  def recover_launch(kind, %{chain_id: chain_id, launcher: launcher, transaction_hash: hash})
      when kind in [:launch, :stocks_launch] do
    case launch_candidates(kind, chain_id, launcher) do
      {:ok, candidates} -> match_launch(kind, candidates, String.downcase(hash), :no_review)
      {:error, reason} -> {:pending, reason}
    end
  end

  defp launch_candidates(kind, chain_id, launcher) do
    with {:ok, reviews} <-
           resource(kind)
           |> Ash.Query.filter(string_downcase(signer) == ^String.downcase(launcher))
           |> Ash.Query.sort(inserted_at: :desc)
           |> Ash.read(actor: @system) do
      {:ok, Enum.filter(reviews, &(&1.envelope["chain_id"] == chain_id))}
    end
  end

  defp match_launch(_kind, [], _hash, :no_review), do: {:unlisted, :no_matching_review}
  defp match_launch(_kind, [], _hash, reason), do: {:pending, reason}

  defp match_launch(kind, [review | rest], hash, waiting) do
    case chain_outcome(kind, review.envelope, :launch, hash) do
      {:ok, %{outcome: :confirmed} = outcome} -> adopt_launch(kind, review.id, hash, outcome)
      {:ok, %{outcome: :pending}} -> match_launch(kind, rest, hash, :chain_pending)
      {:ok, %{outcome: _not_this_review}} -> match_launch(kind, rest, hash, waiting)
      {:error, reason} when reason in @not_this_review -> match_launch(kind, rest, hash, waiting)
      {:error, reason} -> match_launch(kind, rest, hash, reason)
    end
  end

  # Under the review's lock, as a browser report takes it, so a report and this
  # recovery of the same press are one after the other and project once. The
  # listed launch's notifications are sent once the transaction has committed.
  # A press that is not confirmed was already resolved before, so nothing here
  # wrote anything for it.
  defp adopt_launch(kind, review_id, hash, outcome) do
    Ash.transaction(resource(kind), fn ->
      with {:ok, op} <- locked_review(kind, review_id),
           {:ok, attempt} <- launch_attempt(kind, op, hash),
           {:ok, op, attempt, notifications} <-
             reconcile(kind, op, attempt, attempt, outcome) do
        {op.human_account_id, attempt.state, notifications}
      else
        {:error, reason} -> Ash.DataLayer.rollback(resource(kind), reason)
      end
    end)
    |> case do
      {:ok, {account_id, :confirmed, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:listed, account_id}

      {:ok, {_account_id, state, _notifications}} ->
        {:pending, {:press_not_confirmed, state}}

      {:error, error} ->
        {:pending, error}
    end
  end

  defp locked_review(kind, id) do
    resource(kind)
    |> Ash.Query.filter(id == ^id)
    |> lock(true)
    |> Ash.read_one(actor: @system)
  end

  defp launch_attempt(kind, op, hash) do
    with {:ok, attempts} <-
           query(kind, op)
           |> Ash.Query.filter(step == :launch)
           |> Ash.Query.sort(inserted_at: :desc)
           |> lock(true)
           |> Ash.read(actor: @system) do
      reported = Enum.find(attempts, &(&1.transaction_hash == hash))
      unreported = Enum.find(attempts, &is_nil(&1.transaction_hash))

      cond do
        reported -> {:ok, reported}
        unreported -> update(unreported, %{transaction_hash: hash, state: :submitted})
        true -> record_press(kind, op, hash)
      end
    end
  end

  defp record_press(kind, op, hash) do
    WalletAttempt
    |> Ash.Changeset.for_create(
      :dispatch,
      %{
        foreign_key(kind) => op.id,
        :step => :launch,
        :envelope => op.envelope,
        :state => :submitted,
        :transaction_hash => hash
      },
      actor: @system
    )
    |> Ash.create(actor: @system)
  end

  defp reconcile(kind, op, current, candidate, %{outcome: state} = outcome)
       when state in [:confirmed, :reverted, :unverified] do
    if current.state == :submitted and current.transaction_hash == candidate.transaction_hash do
      result = outcome[:result] || %{}

      result =
        if outcome[:onchain_bid_id],
          do: Map.put(result, "onchain_bid_id", outcome.onchain_bid_id),
          else: result

      # Clients currently return a canonical verdict and, where available, result
      # logs. Do not invent receipt/block evidence absent from that client result.
      evidence = %{
        "verification" => Atom.to_string(state),
        "transaction_hash" => current.transaction_hash,
        "receipt" => outcome[:receipt]
      }

      with {:ok, notifications} <- project(kind, op, current, state, result),
           {:ok, current} <-
             update(current, %{
               state: state,
               result: result,
               evidence: evidence,
               resolved_at: DateTime.utc_now()
             }),
           {:ok, op} <- progress(kind, op, current),
           do: {:ok, op, current, notifications}
    else
      {:ok, op, current, []}
    end
  end

  defp reconcile(_, op, current, _, _), do: {:ok, op, current, []}

  # Canonical projection identities are auction-address and auction/bid-id,
  # never press IDs. Re-reporting one transaction cannot create another effect.
  # Each returns the listing notifications its writes owe, to be sent after
  # commit; bid rows have no listeners.
  defp project(:bid, op, %{step: :bid}, :confirmed, result),
    do: op |> Autolaunch.LabProjection.project_bid(result) |> unannounced()

  defp project(:launch, op, %{step: :launch}, :confirmed, result),
    do: Autolaunch.LabProjection.project_launch(op, result)

  defp project(:bid, op, %{step: :usdc_bid}, :confirmed, result),
    do: op |> Autolaunch.LabProjection.project_bid(result) |> unannounced()

  defp project(:stocks_launch, op, %{step: :launch}, :confirmed, result),
    do: Autolaunch.Stocks.LabProjection.project_launch(op, result)

  defp project(:bid_settlement, op, %{step: step}, :confirmed, result),
    do: op |> Autolaunch.LabProjection.project_settlement(step, result) |> unannounced()

  defp project(_, _, _, _, _), do: {:ok, []}

  defp unannounced(:ok), do: {:ok, []}
  defp unannounced({:error, error}), do: {:error, error}

  # The parent is only a monotonic review/progress summary. A sibling rejection
  # never changes it; a late approval cannot reopen an ended/replaced review.
  defp progress(
         kind,
         %{terminal_at: nil, step: step} = op,
         %{state: :confirmed, step: step} = attempt
       ) do
    names = Enum.map(op.envelope["arguments"]["steps"], & &1["step"])
    next = names |> Enum.drop_while(&(&1 != Atom.to_string(step))) |> Enum.at(1)

    attrs =
      if next do
        advanced = %{step: String.to_existing_atom(next), state: :prepared}
        if kind == :bid_settlement, do: merge_result(advanced, kind, op, attempt), else: advanced
      else
        attrs = %{
          state:
            if(kind in [:launch, :stocks_launch],
              do: :chain_verified,
              else: :confirmed
            ),
          terminal_at: DateTime.utc_now()
        }

        if kind == :bid,
          do: Map.put(attrs, :onchain_bid_id, attempt.result["onchain_bid_id"]),
          else: merge_result(attrs, kind, op, attempt)
      end

    op
    |> Ash.Changeset.for_update(:project_wallet_confirmation, attrs, actor: @system)
    |> Ash.update(actor: @system)
  end

  defp progress(_, op, _), do: {:ok, op}

  # A settlement keeps every step's verified amounts on the parent row, so the
  # exit's refund and fill are still there when the claim ends the operation.
  defp merge_result(attrs, :bid_settlement, op, attempt),
    do: Map.put(attrs, :result, Map.merge(op.result || %{}, attempt.result))

  defp merge_result(attrs, _kind, _op, attempt), do: Map.put(attrs, :result, attempt.result)

  defp update(attempt, attrs),
    do:
      attempt
      |> Ash.Changeset.for_update(:report, attrs, actor: @system)
      |> Ash.update(actor: @system)

  defp response(kind, op, attempt, dispatch?) do
    with {:ok, attempts} <-
           query(kind, op)
           |> Ash.Query.sort(inserted_at: :asc, id: :asc)
           |> Ash.read(actor: @system) do
      view = view(kind, op)

      {:ok,
       %{
         operation: Map.put(view, :attempts, Enum.map(attempts, &present/1)),
         attempt: attempt && present(attempt),
         dispatch?: dispatch?
       }}
    end
  end

  def decorate(view, %{id: _} = op, kind) do
    attempts =
      query(kind, op) |> Ash.Query.sort(inserted_at: :asc, id: :asc) |> Ash.read!(actor: @system)

    view =
      Enum.reduce(attempts, view, fn attempt, current ->
        field = hash_field(kind, attempt.step)

        if attempt.transaction_hash && is_nil(Map.get(current, field)),
          do: Map.put(current, field, attempt.transaction_hash),
          else: current
      end)

    view =
      if is_nil(view.terminal_at) and view.state == :prepared do
        active = Enum.filter(attempts, &(&1.step == view.step))

        cond do
          Enum.any?(active, &(&1.state == :submitted)) ->
            Map.put(view, :state, :submitted)

          Enum.any?(active, &(&1.state in [:dispatched, :submission_unknown])) ->
            Map.put(view, :state, :dispatched)

          true ->
            view
        end
      else
        view
      end

    view
    |> Map.put(:revision, op.updated_at)
    |> Map.put(:attempts, Enum.map(attempts, &present/1))
  end

  def decorate(view, _, _), do: Map.put(view, :attempts, [])

  defp present(attempt),
    do:
      Map.take(attempt, [
        :id,
        :step,
        :state,
        :transaction_hash,
        :result,
        :evidence,
        :inserted_at,
        :updated_at,
        :resolved_at
      ])

  defp view(:bid, op), do: Autolaunch.BidActions.view(op)
  defp view(:launch, op), do: Autolaunch.LaunchActions.presented(op)
  defp view(:subject, op), do: Autolaunch.SubjectWalletActions.presented(op)
  defp view(:stocks_launch, op), do: Autolaunch.Stocks.LaunchActions.presented(op)
  defp view(:bid_settlement, op), do: Autolaunch.BidSettlementActions.presented(op)

  defp resource(:bid), do: BidOperation
  defp resource(:launch), do: LaunchOperation
  defp resource(:subject), do: SubjectWalletOperation
  defp resource(:stocks_launch), do: StocksLaunchOperation
  defp resource(:bid_settlement), do: BidSettlementOperation
  defp foreign_key(:bid), do: :bid_operation_id
  defp foreign_key(:launch), do: :launch_operation_id
  defp foreign_key(:subject), do: :subject_wallet_operation_id
  defp foreign_key(:stocks_launch), do: :stock_launch_operation_id
  defp foreign_key(:bid_settlement), do: :bid_settlement_operation_id
  defp actions(:bid), do: Autolaunch.BidActions
  defp actions(:launch), do: Autolaunch.LaunchActions
  defp actions(:subject), do: Autolaunch.SubjectWalletActions
  defp actions(:stocks_launch), do: Autolaunch.Stocks.LaunchActions
  defp actions(:bid_settlement), do: Autolaunch.BidSettlementActions
  defp client(:bid), do: Autolaunch.ChainClient.module()
  defp client(:launch), do: Autolaunch.LaunchChainClient.module()
  defp client(:subject), do: Autolaunch.SubjectWalletChainClient.module()
  defp client(:stocks_launch), do: Autolaunch.Stocks.LabLaunchChainClient

  defp client(:bid_settlement),
    do:
      Application.get_env(
        :autolaunch,
        :autolaunch_bid_settlement_chain_client,
        Autolaunch.LabBidSettlementChainClient
      )

  defp unavailable(reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: WalletAttempt, reason: reason)}
end
