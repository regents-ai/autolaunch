defmodule Autolaunch.Stocks.FeeAdminActions do
  @moduledoc """
  The one boundary between a fee administrator's wallet and the Stocks launchpad.

  Preparation reads the fork once, refuses a wallet the launchpad would refuse
  (only the administrator configures the lane or proposes a successor; only the
  proposed wallet accepts) and writes one immutable envelope with one `action`
  step. Every durable write after that runs inside
  `SessionAuthority.transact_lease/3` against the account that callback locked,
  exactly as the other wallet lanes do.

  Nothing here defers or gates a press on page state. A review is claimed on the
  signer and the reviewed envelope alone; a configuration version that moved in
  the meantime is refused by the contract itself and comes back as a revert.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.{FeeAdminChainClient, FeeAdminOperations, Lab}

  @contract_name "StocksLaunchpadV1"
  @kinds [:configure_subject, :propose_administrator, :accept_administrator]
  @zero_address "0x" <> String.duplicate("0", 40)

  @action_name %{
    configure_subject: "stocks_fee_configure_subject",
    propose_administrator: "stocks_fee_propose_administrator",
    accept_administrator: "stocks_fee_accept_administrator"
  }

  @future_only "This applies to future trades only; revenue already set aside keeps its destination."

  @risk %{
    configure_subject:
      "Your wallet changes where this pool's subject revenue lane sends 1% of currency-side volume from every future trade on the local Base fork. #{@future_only} Test assets have no mainnet value.",
    propose_administrator:
      "Your wallet names another wallet as the next fee administrator of this launch. Nothing changes until that wallet accepts. Local Base fork; test assets have no mainnet value.",
    accept_administrator:
      "Your wallet becomes this launch's fee administrator, the only account that can turn its subject revenue lane on, off or onto another destination. Local Base fork; test assets have no mainnet value."
  }

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed action expired before it was sent"
  @unresolved "account started a new action while this one was unresolved"
  @reverted "verified revert on the local fork"
  @contradicted "canonical receipt contradicts the reviewed action"

  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]
  @identity [:state, :step, :envelope, :action_transaction_hash]

  def future_only_copy, do: @future_only

  @spec wallet_state(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         do: {:ok, %{signer: signer}}
  end

  @doc "Reviews one action on one Stocks auction: one snapshot, one envelope, one operation."
  @spec prepare(String.t(), String.t(), atom(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(auction_id, address, kind, params, opts) when kind in @kinds do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, auction} <- stocks_auction(auction_id),
         {:ok, candidate} <- candidate_splitter(kind, params),
         {:ok, config} <- stocks_lab(),
         {:ok, snapshot} <- snapshot(auction.auction_address, candidate),
         {:ok, plan} <- plan(kind, params, snapshot, signer, config),
         {:ok, operation} <-
           open(lease, auction, signer, kind, review(auction, kind, plan, signer, snapshot)) do
      {:ok, %{operation: operation}}
    end
  end

  def prepare(_auction_id, _address, _kind, _params, _opts), do: unavailable(:unknown_action)

  @doc """
  Everything the launchpad will execute for one action, derived from the
  snapshot and the signer. Exposed so the wallet card and the envelope test
  state exactly the same bytes.

  The administrator alone may configure the lane or propose a successor, and
  only the proposed wallet may accept; anyone else is refused here rather than
  in a wallet. The current configuration version travels as `expectedVersion`,
  so a version that moves before the send reverts on the contract.
  """
  def plan(:configure_subject, params, snapshot, signer, config) do
    with :ok <- administrator(snapshot, signer),
         {:ok, splitter} <- candidate_splitter(:configure_subject, params),
         :ok <- authentic(snapshot, splitter) do
      {:ok,
       %{
         splitter: splitter,
         expected_version: snapshot.config.version,
         data:
           launchpad_data(config, "configureSubject(uint256,address,uint32)", [
             snapshot.launch_id,
             splitter || @zero_address,
             snapshot.config.version
           ])
       }}
    end
  end

  def plan(:propose_administrator, params, snapshot, signer, config) do
    with :ok <- administrator(snapshot, signer),
         {:ok, proposed} <- address(params["proposed_administrator"], :invalid_address) do
      {:ok,
       %{
         proposed_administrator: proposed,
         data:
           launchpad_data(config, "proposeFeeAdministrator(uint256,address)", [
             snapshot.launch_id,
             proposed
           ])
       }}
    end
  end

  def plan(:accept_administrator, _params, snapshot, signer, config) do
    with :ok <- proposed(snapshot, signer) do
      {:ok,
       %{
         data: launchpad_data(config, "acceptFeeAdministrator(uint256)", [snapshot.launch_id])
       }}
    end
  end

  defp administrator(%{config: %{administrator: administrator}}, signer) do
    if Address.equal?(administrator, signer), do: :ok, else: unavailable(:not_fee_administrator)
  end

  defp proposed(%{config: %{proposed_administrator: proposed}}, signer) do
    if is_binary(proposed) and Address.equal?(proposed, signer),
      do: :ok,
      else: unavailable(:not_proposed_administrator)
  end

  defp authentic(_snapshot, nil), do: :ok
  defp authentic(%{splitter: :verified}, _candidate), do: :ok
  defp authentic(_snapshot, _candidate), do: unavailable(:subject_splitter_unrecognised)

  # An empty destination turns the lane off; anything else has to be an address.
  defp candidate_splitter(:configure_subject, params) do
    case params |> Map.get("splitter", "") |> to_string() |> String.trim() do
      "" -> {:ok, nil}
      value -> address(value, :subject_splitter_invalid)
    end
  end

  defp candidate_splitter(_kind, _params), do: {:ok, nil}

  defp launchpad_data(config, signature, arguments),
    do: LabAbi.encode(Lab.abi!(config, :launchpad), signature, arguments)

  @doc "Claims the one step's dispatch for the wallet that reviewed it."
  @spec claim_dispatch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_dispatch(action_id, address, opts) do
    with {:ok, signer} <- normalize(address),
         do: write(action_id, opts, claiming(signer))
  end

  defp claiming(signer) do
    fn account, operation ->
      with :ok <- same_signer(operation, signer),
           :ok <- FeeAdminOperations.signer_matches(account, operation.signer),
           true <- valid_envelope?(operation) || unavailable(:lab_config_changed),
           do: FeeAdminOperations.update(operation, :claim_dispatch)
    end
  end

  @spec bind_hash(String.t(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind_hash(action_id, :action, hash, opts) do
    with {:ok, hash} <- canonical_hash(hash) do
      write(action_id, opts, fn _account, operation ->
        FeeAdminOperations.bind(operation, hash)
      end)
    end
  end

  def bind_hash(_action_id, _step, _hash, _opts), do: unavailable(:unknown_step)

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
        FeeAdminOperations.update(operation, action, %{reason: @unresolved})
      end)

  @spec open_operation(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_operation(auction_id, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, operation} <- FeeAdminOperations.open(account.id, auction_id, false),
         do: {:ok, %{operation: presented(operation)}}
  end

  @doc "The presenter's whole view of one operation."
  def presented(nil), do: nil

  def presented(operation) do
    operation
    |> Map.take([
      :action_id,
      :auction_id,
      :kind,
      :state,
      :step,
      :signer,
      :envelope,
      :result,
      :reason,
      :action_transaction_hash,
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :stocks_fee_admin)
  end

  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  def step_hash(operation, step) when step in [:action, "action"],
    do: operation.action_transaction_hash

  def step_hash(_operation, _unknown), do: nil

  @doc "Read-only dispatch evidence for a wallet press: the reviewed envelope still stands."
  def press_evidence(operation) do
    if valid_envelope?(operation), do: :ok, else: unavailable(:lab_config_changed)
  end

  # Reviews

  defp review(auction, kind, plan, signer, snapshot) do
    steps = [%{"step" => "action", "to" => snapshot.launchpad, "data" => plan.data}]

    @action_name
    |> Map.fetch!(kind)
    |> Envelope.new(signer, plan.data,
      to: snapshot.launchpad,
      resource: FeeAdminChainClient.resource(),
      contract_name: @contract_name,
      chain_id: Lab.chain_id(),
      lab_binding: snapshot.lab_binding,
      risk_copy: Map.fetch!(@risk, kind),
      arguments: %{
        "auction_id" => auction.id,
        "auction_address" => auction.auction_address,
        "kind" => Atom.to_string(kind),
        "launch_id" => Integer.to_string(snapshot.launch_id),
        "launchpad" => snapshot.launchpad,
        "splitter" => plan[:splitter],
        "proposed_administrator" => plan[:proposed_administrator],
        "expected_version" => plan[:expected_version] && Integer.to_string(plan.expected_version),
        "current_version" => Integer.to_string(snapshot.config.version),
        "current_splitter" => snapshot.config.splitter,
        "current_administrator" => snapshot.config.administrator,
        "current_proposed_administrator" => snapshot.config.proposed_administrator,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "steps" => steps
      }
    )
    |> stored()
  end

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Stored auctions

  defp stocks_auction(auction_id) do
    case Autolaunch.get_public_auction(auction_id) do
      {:ok, %{kind: :stocks} = auction} -> {:ok, auction}
      {:ok, _other} -> unavailable(:auction_not_found)
      {:error, _reason} -> unavailable(:auction_unavailable)
    end
  end

  # Chain snapshot

  defp stocks_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:stocks_unavailable)
    end
  end

  defp snapshot(auction_address, candidate) do
    case FeeAdminChainClient.snapshot(%{auction: auction_address, splitter: candidate}) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # Operations

  defp open(lease, auction, signer, kind, envelope) do
    transact(lease, fn account ->
      with :ok <- FeeAdminOperations.signer_matches(account, signer),
           :ok <- release_undispatched(account.id, auction.id),
           {:ok, operation} <-
             FeeAdminOperations.create(account, %{
               action_id: envelope["action_id"],
               auction_id: auction.id,
               kind: kind,
               envelope: envelope,
               signer: signer,
               step: :action
             }),
           do: {:ok, presented(operation)}
    end)
  end

  defp release_undispatched(account_id, auction_id) do
    case FeeAdminOperations.open(account_id, auction_id, true) do
      {:ok, nil} ->
        :ok

      {:ok, %{state: :prepared} = open} ->
        released(FeeAdminOperations.update(open, :cancel, %{reason: @replaced}))

      {:ok, open} ->
        released(FeeAdminOperations.update(open, :close_submission_unknown, %{reason: @replaced}))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp released({:ok, _closed}), do: :ok
  defp released(error), do: error

  defp valid_envelope?(operation) do
    Envelope.valid?(operation.envelope,
      resource: FeeAdminChainClient.resource(),
      action: Map.fetch!(@action_name, operation.kind),
      signer: operation.signer,
      to: operation.envelope["arguments"]["launchpad"],
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    ) and
      Lab.binding_matches?(
        operation.envelope["metadata"]["lab"],
        FeeAdminChainClient.binding_keys()
      )
  end

  defp transition(action, nil),
    do: fn _account, operation -> FeeAdminOperations.update(operation, action) end

  defp transition(action, reason),
    do: fn _account, operation ->
      FeeAdminOperations.update(operation, action, %{reason: reason})
    end

  defp read_chain(%{state: :submitted} = candidate) do
    case FeeAdminChainClient.verify(
           candidate.envelope,
           :action,
           candidate.action_transaction_hash
         ) do
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

  defp record(operation, %{outcome: :confirmed} = outcome),
    do: FeeAdminOperations.update(operation, :confirm, %{result: outcome[:result] || %{}})

  defp record(operation, %{outcome: :reverted}),
    do: FeeAdminOperations.update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: FeeAdminOperations.update(operation, :record_unverified, %{reason: @contradicted})

  defp record(operation, _unresolved), do: {:ok, operation}

  defp expire_lapsed(%{state: :prepared, envelope: %{"expires_at" => expires_at}} = operation) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)

    if DateTime.compare(expires_at, Envelope.current_time()) != :gt,
      do: FeeAdminOperations.update(operation, :expire, %{reason: @lapsed}),
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

  defp transact(lease, callback), do: FeeAdminOperations.transact(lease, callback)

  defp operation(account_id, action_id, lock?),
    do: FeeAdminOperations.fetch(account_id, action_id, lock?)

  defp same_signer(%{signer: signer}, signer), do: :ok
  defp same_signer(_operation, _other), do: unavailable(:wrong_signer)

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
         {:ok, account} <- leased(lease),
         :ok <- FeeAdminOperations.signer_matches(account, signer),
         do: {:ok, signer}
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  # Shared helpers

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp normalize(value), do: address(value, :invalid_address)

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  defp unavailable(reason), do: FeeAdminOperations.unavailable(reason)
end
