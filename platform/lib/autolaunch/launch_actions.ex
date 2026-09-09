defmodule Autolaunch.LaunchActions do
  @moduledoc """
  The one boundary between a founder's wallet and the launch factory.

  Preparation reads Base once, at one canonical safe block, and writes the whole
  reviewed sequence as a single immutable envelope: at most an exact REGENT
  allowance correction, then the one `launch` call it enables. Every durable
  write after that runs inside `SessionAuthority.transact_lease/3` as the
  outermost transaction, against the account that callback locked, so a claim, a
  bound hash or a settled outcome cannot outlive a concurrent logout.

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
  alias Autolaunch.Chain.{Abi, Address, Envelope, LaunchAbi, Rpc}

  alias Autolaunch.{
    Lab,
    LabAbi,
    LabProjection,
    LaunchChainClient,
    LaunchDraft,
    LaunchDraftImageStorage,
    LaunchOperations,
    TreasurySecurity
  }

  @resource "autolaunch_launch"
  @action "autolaunch_launch"
  @contract_name "RegentsAutolaunchFactoryV1"
  @regent_decimals 18

  # The factory's own inclusive byte caps on the five metadata strings. Each must
  # also be nonempty, which is what a historical draft can fail.
  @metadata [name: 64, symbol: 16, description: 512, website: 256]

  # Three of the exact six treasuries the strategy refuses are frozen constants
  # rather than reads: autolaunch-contracts 5cf4a6b48388d54593b83230342542fee7c0f131
  # src/bindings/BaseBindings.sol lines 19-21, refused together with the factory,
  # the strategy and its hook at src/strategy/RegentLBPStrategy.sol lines 673-679.
  @frozen_refused_treasuries [
    "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
    "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5"
  ]

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed launch expired before it was sent"
  @unresolved "account started a new launch while this one was unresolved"
  @reverted "verified revert on Base"
  @contradicted "canonical receipt contradicts the reviewed launch"

  # Exactly what a fresh pre-dispatch read is allowed to disagree about, named so
  # the customer is told which fact moved rather than shown a generic failure.
  @moved "the reviewed factory binding changed"
  @paused "launches were paused after this review"
  @stale_fee "the launch fee changed after this review"
  @short "this wallet no longer holds the launch fee"
  @allowance_moved "the REGENT allowance changed after this review"

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  # Everything a Base read was answered about. A settlement applies only to a row
  # still carrying all of it.
  @identity [:state, :step, :envelope, :approval_transaction_hash, :launch_transaction_hash]

  @doc """
  Proves the wallet Privy has selected belongs to this account, and nothing more.

  The reported address is untrusted, so it is checked against the account the
  mounted lease resolves to before the page shows a single private fact. No
  provider is reached here: a launch review is the one thing that reads Base.
  """
  @spec wallet_state(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         do: {:ok, %{signer: signer}}
  end

  @doc """
  Reviews one saved draft: one snapshot, one immutable envelope, one operation.

  The sequence carries only the transactions this wallet still needs — the exact
  allowance correction when the standing allowance is not already the fee, then
  the single `launch` call it enables.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(draft_id, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, draft} <- owned_draft(draft_id, actor),
         {:ok, fields} <- launchable(draft, actor),
         {:ok, snapshot} <- snapshot(signer),
         :ok <- reviewable(fields, snapshot),
         {:ok, treasury_report} <- review_treasury(draft),
         {:ok, operation} <-
           open(lease, draft, signer, review(draft, fields, signer, snapshot, treasury_report)) do
      {:ok, %{operation: operation}}
    end
  end

  @doc """
  Claims the current step's dispatch. Only this winner may open the wallet.

  Base is read again first, outside any transaction, and compared to the
  immutable review. A review the chain has moved past is ended inside the locked
  transaction rather than refused, so its bytes can never be spent later. The
  locked account, the stored signer and the address the browser is offering right
  now all have to agree inside that same transaction.
  """
  @spec claim_dispatch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_dispatch(action_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, fresh} <- snapshot(candidate.signer),
         treasury_result <- revalidate_treasury(candidate) do
      transact(
        lease,
        &locked(&1, action_id, claiming(signer, candidate, fresh, treasury_result))
      )
    end
  end

  @doc "Binds the first valid hash for the step the browser was actually sent."
  @spec bind_hash(String.t(), atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind_hash(action_id, step, hash, opts) when step in [:approval, :launch] do
    with {:ok, hash} <- canonical_hash(hash) do
      write(action_id, opts, fn _account, operation ->
        LaunchOperations.bind(operation, step, hash)
      end)
    end
  end

  def bind_hash(_action_id, _step, _hash, _opts), do: unavailable(:unknown_step)

  @doc """
  Reads the exact bound hash and records whatever it truthfully settles as.

  Base is read from the candidate row alone, before any lease transaction opens,
  so no provider call ever happens under a row lock. The locked row then has to
  still be that same candidate — same state, step, bound hashes and reviewed
  envelope — or the outcome is dropped rather than applied to a step it never
  described.

  A hash the chain has not resolved writes nothing at all, so the same hash can
  be read again later, and a read that fails writes no verdict either.
  """
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(action_id, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, outcome} <- read_chain(candidate),
         do: transact(lease, &locked(&1, action_id, settle(candidate, outcome)))
  end

  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(action_id, opts), do: write(action_id, opts, transition(:cancel, @withdrawn))

  @spec close_not_sent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def close_not_sent(action_id, opts),
    do: write(action_id, opts, transition(:close_not_sent, @rejected))

  @spec release_unstarted(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def release_unstarted(action_id, opts),
    do: write(action_id, opts, transition(:release_unstarted, nil))

  @doc """
  Ends a launch whose claimed step never resolved, at the account's request.

  Its calldata is never resent and its bound hashes stay exactly where they are.
  The row remains for the canonical projector; only this account's open slot is
  released.
  """
  @spec start_new(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_new(action_id, opts),
    do:
      write(action_id, opts, fn _account, operation ->
        action = if operation.state == :prepared, do: :cancel, else: :close_submission_unknown
        LaunchOperations.update(operation, action, %{reason: @unresolved})
      end)

  @doc """
  The account's open launch, recovered under its current lease.

  Recovery reads private facts, so it requires the same current lease every other
  path does. Nothing is written, and a missing, revoked or account-mismatched
  lease is refused without naming a single fact of whatever operation may exist.
  """
  @spec open_operation(keyword()) :: {:ok, map()} | {:error, term()}
  def open_operation(opts) do
    with {:ok, actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, operation} <- LaunchOperations.open(account.id, false),
         do: {:ok, %{operation: presented(operation)}}
  end

  @doc "The presenter's whole view of one operation. Everything else stays server-side."
  @spec presented(Ash.Resource.record() | nil) :: map() | nil
  def presented(nil), do: nil

  def presented(operation) do
    Map.take(operation, [
      :action_id,
      :launch_draft_id,
      :state,
      :step,
      :signer,
      :envelope,
      :result,
      # Plain English already, and the one fact that moved is what the customer
      # has to be told when a review is ended without ever being sent.
      :reason,
      :approval_transaction_hash,
      :launch_transaction_hash,
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :launch)
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
    do: LaunchOperations.hash(operation, :approval)

  def step_hash(operation, step) when step in [:launch, "launch"],
    do: LaunchOperations.hash(operation, :launch)

  def step_hash(_operation, _unknown), do: nil

  @doc "The founder-frozen terms, in the order a review presents their exact values."
  @spec terms() :: [String.t()]
  def terms, do: Enum.map(LaunchAbi.terms(), &Atom.to_string/1)

  # The exact decimal rendering of an atomic REGENT amount.
  defp regent_units(amount), do: Rpc.format_units(amount, @regent_decimals)

  # Reviews

  defp review(draft, fields, signer, snapshot, treasury_report) do
    {launch_data, envelope_options} = launch_data(fields, snapshot)

    steps =
      approval_step(snapshot) ++
        [%{"step" => "launch", "to" => snapshot.factory, "data" => launch_data}]

    @action
    |> Envelope.new(
      signer,
      launch_data,
      envelope_options ++
        [
          to: snapshot.factory,
          resource: @resource,
          contract_name: @contract_name,
          risk_copy: risk_copy(snapshot.fee, snapshot),
          arguments: arguments(draft, fields, snapshot, steps, treasury_report)
        ]
    )
    |> stored()
  end

  defp launch_data(fields, %{lab_binding: binding} = snapshot) do
    config = Lab.current!()

    data =
      LabAbi.encode(
        Lab.abi!(config, :factory),
        "launch((string,string,string,string,string,address,uint128,uint256))",
        [
          [
            fields.name,
            fields.symbol,
            fields.description,
            fields.website,
            fields.image,
            fields.treasury,
            fields.required_regent_raised,
            snapshot.fee
          ]
        ]
      )

    {data, [chain_id: Lab.chain_id(), lab_binding: binding]}
  end

  defp launch_data(fields, snapshot),
    do: {LaunchAbi.encode_launch(Map.put(fields, :expected_launch_fee, snapshot.fee)), []}

  # One stored shape: the envelope is written, read and rendered exactly as the
  # confirmation token signed it.
  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # The exact C4 allowance rule, zero included: an allowance that already equals
  # the fee is spent as it stands, and anything else — higher, lower, or a
  # residue left by a fee that moved — is corrected to exactly the fee first.
  # There is no additive approval, no unlimited approval and no other spender.
  defp approval_step(%{allowance: fee, fee: fee}), do: []

  defp approval_step(snapshot) do
    [
      %{
        "step" => "approval",
        "to" => regent_address(snapshot),
        "data" => encode_regent_approval(snapshot, snapshot.factory, snapshot.fee),
        "amount" => Integer.to_string(snapshot.fee),
        "spender" => snapshot.factory
      }
    ]
  end

  defp arguments(draft, fields, snapshot, steps, treasury_report) do
    %{
      "draft_id" => draft.id,
      "name" => fields.name,
      "symbol" => fields.symbol,
      "description" => fields.description,
      "website" => fields.website,
      "image" => fields.image,
      "treasury" => fields.treasury,
      "treasury_security" => treasury_binding(treasury_report),
      "required_regent_raised" => draft.required_regent_raised,
      "required_regent_raised_atomic" => Integer.to_string(fields.required_regent_raised),
      "expected_launch_fee_atomic" => Integer.to_string(snapshot.fee),
      "expected_launch_fee" => regent_units(snapshot.fee),
      "allowance_atomic" => Integer.to_string(snapshot.allowance),
      "regent" => regent_address(snapshot),
      "factory" => snapshot.factory,
      "strategy" => snapshot.strategy,
      "block_number" => snapshot.block.number,
      "block_hash" => snapshot.block.hash,
      "terms" => Map.new(snapshot.terms, fn {id, value} -> {to_string(id), to_string(value)} end),
      "steps" => steps
    }
  end

  defp risk_copy(0, %{lab_binding: _binding}),
    do:
      "Your wallet creates this launch on a Base fork with test assets and no mainnet value. The launch fee is zero."

  defp risk_copy(fee, %{lab_binding: _binding}),
    do:
      "Your wallet spends #{regent_units(fee)} forked REGENT to create this launch on a Base fork. Test assets have no mainnet value."

  defp risk_copy(0, _snapshot),
    do:
      "Your wallet creates this launch on Base. The launch fee is zero right now, so no REGENT moves. A launch cannot be undone."

  defp risk_copy(fee, _snapshot),
    do:
      "Your wallet pays #{regent_units(fee)} REGENT to create this launch on Base. A launch cannot be undone."

  # Stored drafts

  # The draft is read through the owner's own `mine` action, so a draft this
  # account does not hold is never even named.
  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft(draft_id, actor: actor) do
      {:ok, draft} -> found(draft)
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end

  defp found(nil), do: unavailable(:launch_draft_not_found)
  defp found(draft), do: {:ok, draft}

  # Everything the factory itself requires of a saved draft. A row written before
  # the nonempty rule, or one carrying an amount this factory cannot hold, is
  # refused here rather than reverting in the customer's wallet.
  defp launchable(draft, actor) do
    with :ok <- metadata(draft),
         {:ok, image} <- launch_image(draft, actor),
         true <- LaunchDraft.treasury_complete?(draft),
         {:ok, treasury} <- address(draft.treasury, :launch_treasury_invalid),
         {:ok, atomic} <- atomic_raise(draft.required_regent_raised) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: draft.website,
         image: image,
         treasury: treasury,
         required_regent_raised: atomic
       }}
    else
      false -> unavailable(:launch_treasury_invalid)
      error -> error
    end
  end

  defp launch_image(draft, actor) do
    with true <- LaunchDraft.image_complete?(draft),
         {:ok,
          %{
            id: image_id,
            launch_draft_id: image_draft_id
          } = image} <- Autolaunch.get_my_launch_draft_image(draft.id, actor: actor),
         true <- image_id == draft.launch_draft_image_id,
         true <- image_draft_id == draft.id,
         expected <- LaunchDraftImageStorage.public_url(image),
         true <- expected == draft.image do
      {:ok, expected}
    else
      _unavailable -> unavailable(:launch_metadata_incomplete)
    end
  end

  defp metadata(draft) do
    if Enum.all?(@metadata, fn {field, limit} -> within?(Map.fetch!(draft, field), limit) end),
      do: :ok,
      else: unavailable(:launch_metadata_incomplete)
  end

  defp within?(value, limit),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit

  defp atomic_raise(value) do
    case LaunchAbi.atomic_raise(value) do
      {:ok, atomic} -> {:ok, atomic}
      :error -> unavailable(:launch_raise_invalid)
    end
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  # Chain snapshot

  defp snapshot(signer) do
    case LaunchChainClient.module().snapshot(%{signer: signer}) do
      {:ok, snapshot} -> complete(snapshot)
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp regent_address(%{regent: regent} = snapshot) do
    if accepted_regent?(snapshot), do: regent, else: nil
  end

  defp regent_address(_snapshot), do: nil

  defp accepted_regent?(%{regent: regent}),
    do: Address.equal?(regent, Abi.regent_address())

  defp accepted_regent?(_snapshot), do: false

  defp encode_regent_approval(%{lab_binding: _binding}, spender, amount) do
    config = Lab.current!()
    LabAbi.encode(Lab.abi!(config, :token), "approve(address,uint256)", [spender, amount])
  end

  defp encode_regent_approval(_snapshot, spender, amount),
    do: Abi.encode_erc20("approve", [spender, amount])

  # A review is derived from one whole snapshot or from none, so a partial answer
  # is refused before any of it is believed.
  defp complete(snapshot) do
    with %{factory: factory, strategy: strategy, strategy_factory: bound} <- snapshot,
         %{fee: fee, allowance: allowance, balance: balance, hook: hook} <- snapshot,
         %{paused: paused, terms: terms, block: block} <- snapshot,
         true <-
           Enum.all?([factory, strategy, bound, hook], &match?({:ok, _}, Address.normalize(&1))),
         true <- Enum.all?([fee, allowance, balance], &(is_integer(&1) and &1 >= 0)),
         true <- is_boolean(paused),
         true <- match?(%{number: number, hash: _} when is_integer(number), block),
         true <- Enum.sort(Map.keys(terms)) == Enum.sort(LaunchAbi.terms()),
         true <- Enum.all?(Map.values(terms), &is_integer/1) do
      {:ok, snapshot}
    else
      _partial -> unavailable(:launch_snapshot_incomplete)
    end
  end

  # Every reason a launch is refused before a durable review can exist at all.
  defp reviewable(fields, snapshot) do
    cond do
      not accepted_regent?(snapshot) -> unavailable(:regent_address_mismatch)
      snapshot.paused -> unavailable(:launches_paused)
      snapshot.balance < snapshot.fee -> unavailable(:insufficient_regent)
      refused_treasury?(fields.treasury, snapshot) -> unavailable(:launch_treasury_refused)
      # Two separate ceilings: the reviewed strategy's own reachable maximum,
      # which is a chain-supplied value, and the structural limit of the
      # `uint128` field the tuple carries it in.
      fields.required_regent_raised > snapshot.terms.max_reachable_raise -> excessive()
      fields.required_regent_raised > LaunchAbi.uint128_max() -> excessive()
      not same?(snapshot.strategy_factory, snapshot.factory) -> unavailable(:strategy_not_bound)
      true -> :ok
    end
  end

  # The exact six the strategy refuses as a launch treasury: the factory, the
  # strategy and the hook it is bound to, all read at the reviewed block, plus the
  # three frozen Base bindings.
  defp refused_treasury?(treasury, %{factory: factory, strategy: strategy, hook: hook}),
    do: Enum.any?([factory, strategy, hook | @frozen_refused_treasuries], &same?(treasury, &1))

  defp excessive, do: unavailable(:required_raise_unreachable)

  def press_evidence(operation) do
    with {:ok, fresh} <- snapshot(operation.signer),
         {:ok, treasury} <- revalidate_treasury(operation),
         true <- valid_envelope?(operation),
         :ok <- still_reviewed(operation, fresh, treasury),
         do: :ok,
         else: (_ -> unavailable(:launch_step_moved))
  end

  # Operations

  defp open(lease, draft, signer, envelope) do
    transact(lease, fn account ->
      with :ok <- LaunchOperations.signer_matches(account, signer),
           :ok <- release_undispatched(account.id),
           {:ok, operation} <-
             LaunchOperations.create(account, %{
               action_id: envelope["action_id"],
               launch_draft_id: draft.id,
               envelope: envelope,
               signer: signer,
               step: first_step(envelope)
             }),
           do: {:ok, presented(operation)}
    end)
  end

  defp first_step(envelope),
    do: envelope["arguments"]["steps"] |> hd() |> Map.fetch!("step") |> String.to_existing_atom()

  # A new prepare always cancels whatever is open as :replaced and proceeds.
  defp release_undispatched(account_id) do
    case LaunchOperations.open(account_id, true) do
      {:ok, nil} ->
        :ok

      {:ok, open} ->
        replace_open(open)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_open(%{state: :prepared} = open) do
    with {:ok, _cancelled} <- LaunchOperations.update(open, :cancel, %{reason: @replaced}),
         do: :ok
  end

  defp replace_open(open) do
    with {:ok, _cancelled} <-
           LaunchOperations.update(open, :close_submission_unknown, %{reason: @replaced}),
         do: :ok
  end

  # The wallet the browser is offering right now, the signer this review pinned,
  # and the account the lease locked all have to name one wallet, inside the one
  # transaction that takes the row. Only then is Base's own current answer
  # compared with what the review promised.
  defp claiming(signer, candidate, fresh, fresh_treasury) do
    fn account, operation ->
      with :ok <- same_signer(operation, signer),
           :ok <- LaunchOperations.signer_matches(account, operation.signer),
           :ok <- unchanged(operation, candidate),
           true <- valid_envelope?(operation) do
        dispatch(operation, fresh, fresh_treasury)
      else
        false ->
          LaunchOperations.update(operation, :invalidate, %{
            reason: "the reviewed network changed"
          })

        error ->
          error
      end
    end
  end

  defp dispatch(operation, _fresh, {:error, _reason}),
    do:
      LaunchOperations.update(operation, :invalidate, %{
        reason: "the treasury security state changed"
      })

  defp dispatch(operation, fresh, {:ok, fresh_treasury}) do
    case still_reviewed(operation, fresh, fresh_treasury) do
      :ok -> LaunchOperations.update(operation, :claim_dispatch)
      {:changed, reason} -> LaunchOperations.update(operation, :invalidate, %{reason: reason})
    end
  end

  # The fresh read answered about the row as it stood outside this transaction. A
  # row another socket has moved since is refused rather than dispatched on an
  # answer that no longer describes it.
  defp unchanged(operation, candidate) do
    if identity(operation) == identity(candidate), do: :ok, else: unavailable(:launch_step_moved)
  end

  # Everything the review promised about Base, checked against Base's answer
  # right now. The allowance rule differs by step on purpose: the correction is
  # still the exact correction it was reviewed as, while the launch is only ever
  # handed over on an allowance that equals the fee exactly, zero included.
  defp still_reviewed(%{step: step} = operation, fresh, fresh_treasury) do
    case treasury_still_reviewed?(operation, fresh_treasury) do
      true -> chain_still_reviewed(operation, step, fresh)
      false -> {:changed, "the treasury security state changed"}
    end
  end

  defp valid_envelope?(operation) do
    options = [
      resource: @resource,
      action: @action,
      signer: operation.signer,
      to: argument(operation, "factory"),
      contract_name: @contract_name
    ]

    options =
      if lab_operation?(operation),
        do: Keyword.put(options, :chain_id, Lab.chain_id()),
        else: options

    Envelope.valid?(operation.envelope, options) and
      (not lab_operation?(operation) or
         Lab.binding_matches?(operation.envelope["metadata"]["lab"], [
           :factory,
           :strategy,
           :hook,
           :regent
         ]))
  end

  defp chain_still_reviewed(operation, step, fresh) do
    cond do
      fresh.paused ->
        {:changed, @paused}

      not same?(fresh.factory, argument(operation, "factory")) ->
        {:changed, @moved}

      not same?(fresh.strategy, argument(operation, "strategy")) ->
        {:changed, @moved}

      not same?(fresh.strategy_factory, fresh.factory) ->
        {:changed, @moved}

      fresh.fee != atomic(operation, "expected_launch_fee_atomic") ->
        {:changed, @stale_fee}

      fresh.balance < fresh.fee ->
        {:changed, @short}

      not allowance_ready?(step, fresh, operation) ->
        {:changed, @allowance_moved}

      true ->
        :ok
    end
  end

  defp allowance_ready?(:approval, fresh, operation),
    do: fresh.allowance == atomic(operation, "allowance_atomic")

  defp allowance_ready?(:launch, fresh, _operation), do: fresh.allowance == fresh.fee

  defp review_treasury(draft) do
    if Lab.enabled?() do
      {:ok,
       %{
         "mode" => "local_lab",
         "address" => draft.treasury,
         "path" => Atom.to_string(draft.treasury_path)
       }}
    else
      production_treasury(draft)
    end
  end

  defp production_treasury(draft) do
    case Autolaunch.current_treasury_security(draft.treasury, actor: nil) do
      {:ok, nil} ->
        unavailable(:treasury_report_missing)

      {:ok, report} ->
        with {:ok, report} <-
               TreasurySecurity.revalidate_bound(report, treasury_requirement(draft)),
             :ok <- custody_address_matches(draft, report),
             :ok <- custody_matches(draft, report),
             do: {:ok, report}

      _error ->
        unavailable(:treasury_report_missing)
    end
  end

  defp treasury_requirement(%{treasury_path: :safe}), do: :verified
  defp treasury_requirement(_advanced), do: :observed

  defp custody_matches(%{treasury_path: :safe}, %{classification: :supported_safe}), do: :ok
  defp custody_matches(%{treasury_path: :eoa}, %{classification: :eoa}), do: :ok

  defp custody_matches(%{treasury_path: :contract}, %{classification: classification})
       when classification in [
              :delegated_eoa,
              :unknown_contract,
              :safe_1_of_1,
              :split,
              :unsupported
            ],
       do: :ok

  defp custody_matches(_draft, _report), do: unavailable(:treasury_security_changed)

  defp custody_address_matches(%{treasury: address}, %{address: report_address}) do
    if Address.equal?(address, report_address),
      do: :ok,
      else: unavailable(:treasury_security_changed)
  end

  defp revalidate_treasury(operation) do
    binding = argument(operation, "treasury_security")

    if binding["mode"] == "local_lab" do
      if valid_lab_treasury?(operation, binding),
        do: {:ok, binding},
        else: unavailable(:treasury_security_changed)
    else
      revalidate_production_treasury(binding)
    end
  end

  defp revalidate_production_treasury(binding) do
    with {:ok, report} <-
           Autolaunch.get_treasury_security_report(binding["report_id"], actor: nil),
         false <- is_nil(report),
         true <- report.address == binding["address"],
         requirement <-
           if(binding["verification_state"] == "verified", do: :verified, else: :observed) do
      TreasurySecurity.revalidate_bound(report, requirement)
    else
      true -> unavailable(:treasury_report_missing)
      _error -> unavailable(:treasury_security_changed)
    end
  end

  defp treasury_still_reviewed?(operation, %{"mode" => "local_lab"} = fresh),
    do:
      fresh == argument(operation, "treasury_security") and valid_lab_treasury?(operation, fresh)

  defp treasury_still_reviewed?(operation, fresh) do
    bound = argument(operation, "treasury_security")

    bound["configuration_fingerprint"] == fresh.configuration_fingerprint and
      bound["address"] == fresh.address and
      bound["classification"] == Atom.to_string(fresh.classification) and
      bound["verification_state"] == Atom.to_string(fresh.verification_state) and
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

  defp valid_lab_treasury?(operation, binding) do
    lab_operation?(operation) and
      Address.equal?(binding["address"], argument(operation, "treasury")) and
      Lab.binding_matches?(operation.envelope["metadata"]["lab"], [
        :factory,
        :strategy,
        :hook,
        :regent
      ])
  end

  defp lab_operation?(operation), do: get_in(operation.envelope, ["metadata", "lab"]) != nil

  defp transition(action, nil),
    do: fn _account, operation -> LaunchOperations.update(operation, action) end

  defp transition(action, reason),
    do: fn _account, operation ->
      LaunchOperations.update(operation, action, %{reason: reason})
    end

  # The one Base read a settlement makes, with no transaction and no lock open.
  # A candidate with nothing sent to read about asks nothing.
  defp read_chain(%{state: :submitted} = candidate) do
    hash = LaunchOperations.hash(candidate, candidate.step)

    case LaunchChainClient.module().verify(candidate.envelope, candidate.step, hash) do
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

  defp record(%{step: :approval} = operation, %{outcome: :confirmed} = result),
    do: LaunchOperations.update(operation, :advance, %{result: merged(operation, result)})

  defp record(operation, %{outcome: :confirmed} = result) do
    with :ok <- LabProjection.project_launch(operation, result[:result] || %{}) do
      LaunchOperations.update(operation, :record_chain_verified, %{
        result: merged(operation, result)
      })
    end
  end

  defp record(operation, %{outcome: :reverted}),
    do: LaunchOperations.update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: LaunchOperations.update(operation, :record_unverified, %{reason: @contradicted})

  # A hash the chain has not resolved yet, and a candidate that had nothing to
  # read, both leave the row bound and readable again.
  defp record(operation, _unresolved), do: {:ok, operation}

  defp merged(%{result: result}, outcome), do: Map.merge(result, outcome[:result] || %{})

  # The reviewed envelope lives ten minutes. Past that, no prepared step of it
  # can be spent, so the operation ends here — inside the locked transaction,
  # ahead of the transition — and a new review rereads current state.
  defp expire_lapsed(%{state: :prepared} = operation) do
    if expired?(operation),
      do: LaunchOperations.update(operation, :expire, %{reason: @lapsed}),
      else: {:ok, operation}
  end

  defp expire_lapsed(operation), do: {:ok, operation}

  defp expired?(%{envelope: %{"expires_at" => expires_at}}) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
    DateTime.compare(expires_at, Envelope.current_time()) != :gt
  end

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

  # An operation the lapse just ended is itself the outcome, and it commits:
  # nothing further is asked of bytes that can no longer be spent.
  defp resume(%{state: :expired} = operation, _account, _transition), do: {:ok, operation}
  defp resume(operation, account, transition), do: transition.(account, operation)

  defp transact(lease, callback), do: LaunchOperations.transact(lease, callback)

  defp operation(account_id, action_id, lock?),
    do: LaunchOperations.fetch(account_id, action_id, lock?)

  # A review is prepared for one signer, and only that wallet may dispatch it.
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
         :ok <- LaunchOperations.signer_matches(account, signer),
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

  defp same?(left, right), do: Address.equal?(left, right)

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp atomic(operation, key), do: operation |> argument(key) |> String.to_integer()

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
