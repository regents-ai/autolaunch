defmodule Autolaunch.WalletAttempts do
  @moduledoc """
  Authority → account → review → attempt locking. Provider reads are outside locks.
  Review eligibility admits new presses only; outcomes of issued presses remain
  writable after expiry, withdrawal, replacement or another press's confirmation.
  No recovery path sends a transaction. Legacy reports never select a newest press.
  """
  require Ash.Query
  alias Autolaunch.{WalletAttempt, BidOperation, LaunchOperation, SubjectWalletOperation}
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.Stocks.FeeAdminOperation, as: StocksFeeAdminOperation
  alias Autolaunch.Stocks.LaunchOperation, as: StocksLaunchOperation
  @system %System{}
  @kinds [:bid, :launch, :subject, :stocks_launch, :stocks_fee_admin]

  def dispatch(kind, action_id, step, press_id, signer, opts)
      when kind in @kinds and is_binary(action_id) and (is_binary(step) or is_atom(step)) and
             is_binary(press_id) and is_binary(signer) do
    with {:ok, lease} <- authority(opts),
         {:ok, candidate} <- parent(kind, lease.account_id, action_id, false),
         {:ok, step} <- step(candidate, step),
         {:ok, _uuid} <- Ecto.UUID.cast(press_id),
         :ok <- eligible(candidate, step, signer),
         :ok <- actions(kind).press_evidence(%{candidate | step: step}) do
      transact(lease, fn account ->
        with {:ok, op} <- parent(kind, account.id, action_id, true),
             :ok <- eligible(op, step, signer),
             true <- op.envelope == candidate.envelope,
             true <- Enum.any?(account.wallet_addresses || [], &Address.equal?(&1, signer)),
             {:ok, existing} <- fetch(kind, op, press_id, true) do
          case existing do
            nil ->
              with {:ok, attempt} <- create(kind, op, step, press_id),
                   do: response(kind, op, attempt, true)

            %{step: ^step, envelope: envelope} = attempt when envelope == op.envelope ->
              response(kind, op, attempt, false)

            _ ->
              unavailable(:press_identity_conflict)
          end
        else
          false -> unavailable(:wrong_signer)
          error -> error
        end
      end)
    else
      :error -> unavailable(:invalid_press)
      error -> error
    end
  end

  def dispatch(_, _, _, _, _, _), do: unavailable(:invalid_press)

  def report(kind, action_id, press_id, report, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts) do
      transact(lease, fn account ->
        with {:ok, op} <- parent(kind, account.id, action_id, true),
             {:ok, attempt} <- issued(kind, op, press_id, true),
             true <-
               is_map(report) and
                 (not Map.has_key?(report, "step") or
                    report["step"] == Atom.to_string(attempt.step)),
             {:ok, attempt} <- ingest(attempt, report) do
          response(kind, op, attempt, false)
        else
          false -> unavailable(:submitted_step_mismatch)
          error -> error
        end
      end)
    end
  end

  def verify(kind, action_id, press_id, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts),
         {:ok, candidate} <- parent(kind, lease.account_id, action_id, false),
         {:ok, attempt} <- issued(kind, candidate, press_id, false),
         {:ok, outcome} <- read_chain(kind, attempt) do
      transact(lease, fn account ->
        with {:ok, op} <- parent(kind, account.id, action_id, true),
             {:ok, current} <- issued(kind, op, press_id, true),
             {:ok, op, current} <- reconcile(kind, op, current, attempt, outcome),
             do: response(kind, op, current, false)
      end)
    end
  end

  def report_legacy(kind, action_id, step_name, hash, opts) when kind in @kinds do
    with {:ok, lease} <- authority(opts) do
      transact(lease, fn account ->
        with {:ok, op} <- parent(kind, account.id, action_id, true),
             {:ok, step} <- step(op, step_name),
             {:ok, rows} <-
               query(kind, op)
               |> Ash.Query.filter(legacy == true and step == ^step)
               |> Ash.read(actor: @system),
             {:ok, attempt} <- legacy_attempt(kind, op, step, rows),
             {:ok, attempt} <- ingest(attempt, %{"transaction_hash" => hash}),
             {:ok, op} <- bind_legacy_parent(kind, op, step, attempt.transaction_hash),
             do: response(kind, op, attempt, false)
      end)
    end
  end

  defp bind_legacy_parent(kind, op, step, hash) do
    attribute = hash_field(kind, step)

    cond do
      Map.get(op, attribute) == hash ->
        {:ok, op}

      Map.get(op, attribute) != nil ->
        unavailable(:submitted_hash_conflict)

      op.step != step ->
        {:ok, op}

      true ->
        action = if op.terminal_at, do: :attach_late_hash, else: :bind_hash

        op
        |> Ash.Changeset.for_update(action, %{attribute => hash}, actor: @system)
        |> Ash.update(actor: @system)
    end
  end

  defp hash_field(kind, step) do
    case {kind, step} do
      {:bid, :token_approval} -> :token_approval_transaction_hash
      {:bid, :permit2_approval} -> :permit2_approval_transaction_hash
      {:bid, :bid} -> :bid_transaction_hash
      {:bid, :usdc_approval} -> :usdc_approval_transaction_hash
      {:bid, :usdc_bid} -> :usdc_bid_transaction_hash
      {:launch, :launch} -> :launch_transaction_hash
      {:stocks_launch, :launch} -> :launch_transaction_hash
      {:subject, :action} -> :action_transaction_hash
      {:stocks_fee_admin, :action} -> :action_transaction_hash
      {_, :approval} -> :approval_transaction_hash
    end
  end

  defp legacy_attempt(_, _, _, [attempt]), do: {:ok, attempt}

  defp legacy_attempt(kind, op, step, []) do
    hash = Map.get(op, hash_field(kind, step))
    # Rolling compatibility for an old client that claimed the old parent row
    # after migration. Fresh review/press rows never satisfy this legacy evidence.
    if hash || (op.step == step and op.state in [:dispatched, :submitted, :submission_unknown]) do
      attrs = %{
        foreign_key(kind) => op.id,
        :step => step,
        :envelope => op.envelope,
        :legacy => true,
        :state => if(hash, do: :submitted, else: :submission_unknown),
        :transaction_hash => hash
      }

      WalletAttempt
      |> Ash.Changeset.for_create(:dispatch, attrs, actor: @system)
      |> Ash.create(actor: @system)
    else
      unavailable(:legacy_press_not_found)
    end
  end

  defp legacy_attempt(_, _, _, _), do: unavailable(:legacy_press_ambiguous)

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
      :legacy => false,
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

  defp read_chain(kind, %{state: :submitted} = attempt) do
    module = client(kind)
    Code.ensure_loaded!(module)

    fun =
      if function_exported?(module, :verify_with_evidence, 3),
        do: :verify_with_evidence,
        else: :verify

    apply(module, fun, [attempt.envelope, attempt.step, attempt.transaction_hash])
  end

  defp read_chain(_, _), do: {:ok, nil}

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

      with :ok <- project(kind, op, current, state, result),
           {:ok, current} <-
             update(current, %{
               state: state,
               result: result,
               evidence: evidence,
               resolved_at: DateTime.utc_now()
             }),
           {:ok, op} <- progress(kind, op, current),
           do: {:ok, op, current}
    else
      {:ok, op, current}
    end
  end

  defp reconcile(_, op, current, _, _), do: {:ok, op, current}

  # Canonical projection identities are auction-address and auction/bid-id,
  # never press IDs. Re-reporting one transaction cannot create another effect.
  defp project(:bid, op, %{step: :bid}, :confirmed, result),
    do: Autolaunch.LabProjection.project_bid(op, result)

  defp project(:launch, op, %{step: :launch}, :confirmed, result),
    do: Autolaunch.LabProjection.project_launch(op, result)

  defp project(:bid, op, %{step: :usdc_bid}, :confirmed, result),
    do: Autolaunch.LabProjection.project_bid(op, result)

  defp project(:stocks_launch, op, %{step: :launch}, :confirmed, result),
    do: Autolaunch.Stocks.LabProjection.project_launch(op, result)

  defp project(_, _, _, _, _), do: :ok

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
        %{step: String.to_existing_atom(next), state: :prepared}
      else
        attrs = %{
          state: if(kind in [:launch, :stocks_launch], do: :chain_verified, else: :confirmed),
          terminal_at: DateTime.utc_now()
        }

        if kind == :bid,
          do: Map.put(attrs, :onchain_bid_id, attempt.result["onchain_bid_id"]),
          else: Map.put(attrs, :result, attempt.result)
      end

    op
    |> Ash.Changeset.for_update(:project_wallet_confirmation, attrs, actor: @system)
    |> Ash.update(actor: @system)
  end

  defp progress(_, op, _), do: {:ok, op}

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
        :resolved_at,
        :legacy
      ])

  defp view(:bid, op), do: Autolaunch.BidActions.view(op)
  defp view(:launch, op), do: Autolaunch.LaunchActions.presented(op)
  defp view(:subject, op), do: Autolaunch.SubjectWalletActions.presented(op)
  defp view(:stocks_launch, op), do: Autolaunch.Stocks.LaunchActions.presented(op)
  defp view(:stocks_fee_admin, op), do: Autolaunch.Stocks.FeeAdminActions.presented(op)

  defp resource(:bid), do: BidOperation
  defp resource(:launch), do: LaunchOperation
  defp resource(:subject), do: SubjectWalletOperation
  defp resource(:stocks_launch), do: StocksLaunchOperation
  defp resource(:stocks_fee_admin), do: StocksFeeAdminOperation
  defp foreign_key(:bid), do: :bid_operation_id
  defp foreign_key(:launch), do: :launch_operation_id
  defp foreign_key(:subject), do: :subject_wallet_operation_id
  defp foreign_key(:stocks_launch), do: :stock_launch_operation_id
  defp foreign_key(:stocks_fee_admin), do: :stock_fee_admin_operation_id
  defp actions(:bid), do: Autolaunch.BidActions
  defp actions(:launch), do: Autolaunch.LaunchActions
  defp actions(:subject), do: Autolaunch.SubjectWalletActions
  defp actions(:stocks_launch), do: Autolaunch.Stocks.LaunchActions
  defp actions(:stocks_fee_admin), do: Autolaunch.Stocks.FeeAdminActions
  defp client(:bid), do: Autolaunch.ChainClient.module()
  defp client(:launch), do: Autolaunch.LaunchChainClient.module()
  defp client(:subject), do: Autolaunch.SubjectWalletChainClient.module()
  defp client(:stocks_launch), do: Autolaunch.Stocks.LabLaunchChainClient
  defp client(:stocks_fee_admin), do: Autolaunch.Stocks.FeeAdminChainClient

  defp unavailable(reason),
    do: {:error, Ash.Error.Invalid.Unavailable.exception(resource: WalletAttempt, reason: reason)}
end
