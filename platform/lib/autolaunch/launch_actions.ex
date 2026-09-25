defmodule Autolaunch.LaunchActions do
  @moduledoc """
  The one boundary between a founder's wallet and the launch factory.

  Preparation reads Base once, at one canonical safe block, and writes the whole
  reviewed sequence as a single immutable envelope: the one `launch` call. Every durable
  write after that runs inside `SessionAuthority.transact_lease/3` as the
  outermost transaction, against the account that callback locked, so a review
  transition cannot outlive a concurrent logout. Wallet presses of the review
  are `Autolaunch.WalletAttempts`; this module only supplies their evidence.

  The wallet is the one the customer signed in with, which the panel reads from
  its mounted lease. It is still proved against the account that lease resolves
  to before any private fact is read.

  Provider reads always happen before the lease transaction; only the row write
  happens inside it, and the row is taken `FOR UPDATE` first, so two sockets
  racing the same step serialize and exactly one of them wins.
  """

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, LaunchAbi}

  alias Autolaunch.{
    Lab,
    LabAbi,
    LaunchChainClient,
    LaunchDraft,
    LaunchDraftImageStorage,
    LaunchOperations,
    TreasurySecurity
  }

  @resource "autolaunch_launch"
  @action "autolaunch_launch"
  @contract_name "RegentsAutolaunchFactoryV1"

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

  @withdrawn "review withdrawn"
  @lapsed "the reviewed launch expired before it was sent"
  @unresolved "account started a new launch while this one was unresolved"

  # Exactly what a fresh pre-dispatch read is allowed to disagree about, named so
  # the customer is told which fact moved rather than shown a generic failure.
  @moved "the reviewed factory binding changed"
  @paused "launches were paused after this review"

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @doc """
  Proves the signed-in wallet belongs to this account, and nothing more.

  The address is checked against the account the mounted lease resolves to
  before the page shows a single private fact. No
  provider is reached here: a launch review is the one thing that reads Base.
  """
  @spec wallet_state(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         do: {:ok, %{signer: signer}}
  end

  @doc "Reviews one saved draft: one snapshot, one immutable envelope, one operation."
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

  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cancel(action_id, opts), do: write(action_id, opts, transition(:cancel, @withdrawn))

  @doc """
  Ends a launch whose presses have not resolved, at the account's request.

  Withdrawing the review cancels future admission only: every issued press keeps
  its own record and its hash, and nothing is ever resent. The row remains for
  the canonical projector.
  """
  @spec start_new(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_new(action_id, opts),
    do: write(action_id, opts, transition(:cancel, @unresolved))

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
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :launch)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  @spec steps(map()) :: [map()]
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  @doc """
  The hash of the confirmed or pending press for the launch step of a
  presented operation, or `nil`.

  The one reviewed step is named exactly, so any other value has no hash
  rather than becoming an atom.
  """
  @spec step_hash(map(), String.t() | atom()) :: String.t() | nil
  def step_hash(operation, step) when step in [:launch, "launch"],
    do: Map.get(operation, :launch_transaction_hash)

  def step_hash(_operation, _unknown), do: nil

  @doc "The founder-frozen terms, in the order a review presents their exact values."
  @spec terms() :: [String.t()]
  def terms, do: Enum.map(LaunchAbi.terms(), &Atom.to_string/1)

  # Reviews

  defp review(draft, fields, signer, snapshot, treasury_report) do
    launch_data = launch_data(fields)
    steps = [%{"step" => "launch", "to" => snapshot.factory, "data" => launch_data}]

    @action
    |> Envelope.new(signer, launch_data,
      to: snapshot.factory,
      resource: @resource,
      contract_name: @contract_name,
      chain_id: Lab.chain_id(),
      lab_binding: snapshot.lab_binding,
      risk_copy: risk_copy(),
      arguments: arguments(draft, fields, snapshot, steps, treasury_report)
    )
    |> stored()
  end

  defp launch_data(fields) do
    config = Lab.current!()

    LabAbi.encode(
      Lab.abi!(config, :factory),
      "launch((string,string,string,string,string,address,uint128))",
      [
        [
          fields.name,
          fields.symbol,
          fields.description,
          fields.website,
          fields.image,
          fields.treasury,
          fields.required_regent_raised
        ]
      ]
    )
  end

  # One stored shape: the envelope is written, read and rendered exactly as the
  # confirmation token signed it.
  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

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
      "required_regent_raised" => LaunchDraft.onchain_required_raise(draft),
      "required_regent_raised_atomic" => Integer.to_string(fields.required_regent_raised),
      "regent" => snapshot.regent,
      "factory" => snapshot.factory,
      "strategy" => snapshot.strategy,
      "block_number" => snapshot.block.number,
      "block_hash" => snapshot.block.hash,
      "terms" => Map.new(snapshot.terms, fn {id, value} -> {to_string(id), to_string(value)} end),
      "steps" => steps
    }
  end

  defp risk_copy do
    if Lab.test_chain?(),
      do:
        "Your wallet creates this launch on a Base fork with test assets and no mainnet value. There is no launch fee.",
      else:
        "Your wallet creates this launch on Base. There is no launch fee, so no REGENT moves. A launch cannot be undone."
  end

  # Stored drafts

  # The draft is read through the owner's own `mine` action, so a draft this
  # account does not hold is never even named.
  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft(draft_id, actor: actor) do
      {:ok, nil} -> unavailable(:launch_draft_not_found)
      {:ok, draft} -> {:ok, draft}
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end

  # Everything the factory itself requires of a saved draft. A row written before
  # the nonempty rule, or one carrying an amount this factory cannot hold, is
  # refused here rather than reverting in the customer's wallet.
  defp launchable(draft, actor) do
    with :ok <- metadata(draft),
         {:ok, image} <- launch_image(draft, actor),
         true <- LaunchDraft.treasury_complete?(draft),
         {:ok, treasury} <- address(draft.treasury, :launch_treasury_invalid),
         {:ok, atomic} <- atomic_raise(LaunchDraft.onchain_required_raise(draft)) do
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

  defp accepted_regent?(%{regent: regent}),
    do: Address.equal?(regent, Abi.regent_address())

  defp accepted_regent?(_snapshot), do: false

  # A review is derived from one whole snapshot or from none, so a partial answer
  # is refused before any of it is believed.
  defp complete(snapshot) do
    with %{factory: factory, strategy: strategy, strategy_factory: bound, hook: hook} <- snapshot,
         %{paused: paused, terms: terms, block: block} <- snapshot,
         true <-
           Enum.all?([factory, strategy, bound, hook], &match?({:ok, _}, Address.normalize(&1))),
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
      not accepted_regent?(snapshot) ->
        unavailable(:regent_address_mismatch)

      snapshot.paused ->
        unavailable(:launches_paused)

      refused_treasury?(fields.treasury, snapshot) ->
        unavailable(:launch_treasury_refused)

      # Two separate ceilings: the reviewed strategy's own reachable maximum,
      # which is a chain-supplied value, and the structural limit of the
      # `uint128` field the tuple carries it in.
      fields.required_regent_raised > snapshot.terms.max_reachable_raise ->
        excessive()

      fields.required_regent_raised > LaunchAbi.uint128_max() ->
        excessive()

      not same?(snapshot.strategy_factory, snapshot.factory) ->
        unavailable(:strategy_not_bound)

      true ->
        :ok
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
           {:ok, operation} <-
             LaunchOperations.create(account, %{
               action_id: envelope["action_id"],
               launch_draft_id: draft.id,
               envelope: envelope,
               signer: signer,
               step: :launch
             }),
           do: {:ok, presented(operation)}
    end)
  end

  # Everything the review promised about Base, checked against Base's answer
  # right now.
  defp still_reviewed(operation, fresh, fresh_treasury) do
    case treasury_still_reviewed?(operation, fresh_treasury) do
      true -> chain_still_reviewed(operation, fresh)
      false -> {:changed, "the treasury security state changed"}
    end
  end

  defp valid_envelope?(operation) do
    options = [
      resource: @resource,
      action: @action,
      signer: operation.signer,
      to: argument(operation, "factory"),
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    ]

    Envelope.valid?(operation.envelope, options) and
      Lab.binding_matches?(operation.envelope["metadata"]["lab"], [
        :factory,
        :strategy,
        :hook,
        :regent
      ])
  end

  defp chain_still_reviewed(operation, fresh) do
    cond do
      fresh.paused ->
        {:changed, @paused}

      not same?(fresh.factory, argument(operation, "factory")) ->
        {:changed, @moved}

      not same?(fresh.strategy, argument(operation, "strategy")) ->
        {:changed, @moved}

      not same?(fresh.strategy_factory, fresh.factory) ->
        {:changed, @moved}

      true ->
        :ok
    end
  end

  defp review_treasury(draft) do
    if Lab.test_chain?() do
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
    Address.equal?(binding["address"], argument(operation, "treasury")) and
      Lab.binding_matches?(operation.envelope["metadata"]["lab"], [
        :factory,
        :strategy,
        :hook,
        :regent
      ])
  end

  defp transition(action, reason),
    do: fn _account, operation ->
      LaunchOperations.update(operation, action, %{reason: reason})
    end

  # The reviewed envelope lives ten minutes. Past that, no prepared step of it
  # can be spent, so the operation ends here — inside the locked transaction,
  # ahead of the transition — and a new review rereads current state.
  defp expire_lapsed(%{state: :prepared} = operation) do
    if expired?(operation) and not Autolaunch.WalletAttempts.in_flight?(:launch, operation),
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

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp same?(left, right), do: Address.equal?(left, right)

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
