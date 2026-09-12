defmodule Autolaunch.Robinhood.LaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Robinhood Revshare launchpad.

  Preparation reads the local Robinhood lab once and writes the whole reviewed
  sequence as a single immutable envelope: at most an exact USDG allowance
  correction for the launch fee, then the one `launch(LaunchParams)` call it
  enables. Every durable write after that runs inside
  `SessionAuthority.transact_lease/3` against the account that callback locked,
  through the same `LaunchOperation` rows the Base launch uses.

  The review derives the executable values from the saved Robinhood draft and
  the chain: the first bidding block a fixed lead past the current lab block, a
  fixed floor price, the USDG raise the creator entered checked against the
  launchpad's minimum, and the launch fee the launchpad charges right now, which
  the tuple carries as `expectedLaunchFee` so a fee that moves reverts rather
  than overcharges.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LaunchDraft, LaunchOperations}
  alias Autolaunch.Robinhood.{Lab, LaunchChainClient}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.Amounts

  @resource "autolaunch_robinhood_launch"
  @action "autolaunch_robinhood_launch"
  @contract_name "RobinhoodRevshareLaunchpadV1"

  @usdg_decimals 6
  @auction_duration_blocks 43_200
  # The launchpad's minimum lead is 300 blocks; the margin covers blocks mined
  # between the review and the send.
  @start_lead_blocks 310
  # Stand-in floor: a currency-per-NEW price of 1e-16 base units per base unit
  # in Q96, on the bid grid. The draft carries no floor price for this chain yet.
  @floor_price_q96 7_922_816_251_400
  @uint128_max Integer.pow(2, 128) - 1
  @metadata [name: 64, symbol: 16, description: 512, website: 256, image: 256]

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed launch expired before it was sent"
  @unresolved "account started a new launch while this one was unresolved"
  @reverted "verified revert on the Robinhood lab"
  @contradicted "canonical receipt contradicts the reviewed launch"
  @paused "launches were paused after this review"
  @moved "the reviewed launchpad binding changed"
  @stale_fee "the launch fee changed after this review"
  @minimum_moved "the minimum raise changed after this review"
  @short "this wallet no longer holds the launch fee"
  @allowance_moved "the USDG allowance changed after this review"

  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]
  @identity [:state, :step, :envelope, :approval_transaction_hash, :launch_transaction_hash]

  @spec wallet_state(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wallet_state(address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         do: {:ok, %{signer: signer}}
  end

  @doc "Reviews one saved Robinhood draft: one snapshot, one immutable envelope, one operation."
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(draft_id, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, draft} <- owned_draft(draft_id, actor),
         {:ok, fields} <- launchable(draft),
         {:ok, config} <- robinhood_lab(),
         {:ok, snapshot} <- snapshot(signer),
         {:ok, executable} <- executable(fields, snapshot),
         {:ok, operation} <-
           open(lease, draft, signer, review(draft, fields, executable, signer, snapshot, config)) do
      {:ok, %{operation: operation}}
    end
  end

  @doc "Claims the current step's dispatch after the lab is read again and compared to the review."
  @spec claim_dispatch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_dispatch(action_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, fresh} <- snapshot(candidate.signer) do
      transact(lease, &locked(&1, action_id, claiming(signer, candidate, fresh)))
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
        LaunchOperations.update(operation, action, %{reason: @unresolved})
      end)

  @spec open_operation(keyword()) :: {:ok, map()} | {:error, term()}
  def open_operation(opts) do
    with {:ok, actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         {:ok, operation} <- LaunchOperations.open(account.id, false),
         do: {:ok, %{operation: presented(operation)}}
  end

  @doc "The presenter's whole view of one operation."
  def presented(nil), do: nil

  def presented(operation) do
    operation
    |> Map.take([
      :action_id,
      :launch_draft_id,
      :state,
      :step,
      :signer,
      :envelope,
      :result,
      :reason,
      :approval_transaction_hash,
      :launch_transaction_hash,
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :robinhood_launch)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  def step_hash(operation, step) when step in [:approval, "approval"],
    do: LaunchOperations.hash(operation, :approval)

  def step_hash(operation, step) when step in [:launch, "launch"],
    do: LaunchOperations.hash(operation, :launch)

  def step_hash(_operation, _unknown), do: nil

  @doc "Read-only dispatch evidence for a wallet press, before any lock is taken."
  def press_evidence(operation) do
    with {:ok, fresh} <- snapshot(operation.signer),
         true <- valid_envelope?(operation),
         :ok <- still_reviewed(operation, fresh),
         do: :ok,
         else: (_ -> unavailable(:launch_step_moved))
  end

  # Executable values

  defp executable(fields, snapshot) do
    with :ok <- admitted(snapshot),
         :ok <- raise_admitted(fields.required_usdg_raised, snapshot.minimum_raise_usdg) do
      start_block = snapshot.block.number + @start_lead_blocks

      {:ok,
       %{
         start_block: start_block,
         end_block: start_block + @auction_duration_blocks,
         floor_price_q96: @floor_price_q96,
         launch_fee: snapshot.fee
       }}
    end
  end

  defp admitted(%{paused: true}), do: unavailable(:launches_paused)

  defp admitted(%{balance: balance, fee: fee}) when balance < fee,
    do: unavailable(:insufficient_usdg)

  defp admitted(_snapshot), do: :ok

  defp raise_admitted(required, minimum) when required < minimum,
    do: unavailable(:launch_raise_below_minimum)

  defp raise_admitted(required, _minimum) when required > @uint128_max,
    do: unavailable(:launch_raise_invalid)

  defp raise_admitted(_required, _minimum), do: :ok

  # Reviews

  defp review(draft, fields, executable, signer, snapshot, config) do
    steps = reviewed_steps(fields, executable, snapshot, config)
    data = steps |> List.last() |> Map.fetch!("data")

    @action
    |> Envelope.new(signer, data,
      to: snapshot.launchpad,
      resource: @resource,
      contract_name: @contract_name,
      chain_id: Lab.chain_id(),
      lab_binding: snapshot.lab_binding,
      risk_copy: risk_copy(snapshot.fee),
      arguments: %{
        "draft_id" => draft.id,
        "name" => fields.name,
        "symbol" => fields.symbol,
        "description" => fields.description,
        "website" => fields.website,
        "image" => fields.image,
        "treasury" => fields.treasury,
        "required_usdg_raised_atomic" => Integer.to_string(fields.required_usdg_raised),
        "required_usdg_raised" => usdg_units(fields.required_usdg_raised),
        "minimum_raise_usdg_atomic" => Integer.to_string(snapshot.minimum_raise_usdg),
        "minimum_raise_usdg" => usdg_units(snapshot.minimum_raise_usdg),
        "start_block" => Integer.to_string(executable.start_block),
        "end_block" => Integer.to_string(executable.end_block),
        "floor_price_q96" => Integer.to_string(executable.floor_price_q96),
        "expected_launch_fee_atomic" => Integer.to_string(snapshot.fee),
        "expected_launch_fee" => usdg_units(snapshot.fee),
        "allowance_atomic" => Integer.to_string(snapshot.allowance),
        "usdg" => snapshot.usdg,
        "launchpad" => snapshot.launchpad,
        "hook" => snapshot.hook,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "steps" => steps
      }
    )
    |> stored()
  end

  # The exact allowance correction when the standing allowance is not already
  # the fee, then the one `launch` call it enables. The launchpad requires the
  # allowance to equal the fee exactly, zero included.
  defp reviewed_steps(fields, executable, snapshot, config) do
    approval_step(snapshot, config) ++
      [
        %{
          "step" => "launch",
          "to" => snapshot.launchpad,
          "data" => launch_data(fields, executable, config)
        }
      ]
  end

  defp approval_step(%{allowance: fee, fee: fee}, _config), do: []

  defp approval_step(%{usdg: usdg, launchpad: launchpad, fee: fee}, config) do
    [
      %{
        "step" => "approval",
        "to" => usdg,
        "data" =>
          LabAbi.encode(Lab.abi!(config, :erc20), "approve(address,uint256)", [launchpad, fee]),
        "amount" => Integer.to_string(fee),
        "spender" => launchpad
      }
    ]
  end

  defp launch_data(fields, executable, config) do
    LabAbi.encode(Lab.abi!(config, :launchpad), RobinhoodLabAbi.launch_signature(), [
      [
        [
          fields.name,
          fields.symbol,
          fields.description,
          fields.website,
          fields.image,
          executable.start_block,
          executable.floor_price_q96,
          executable.launch_fee
        ],
        fields.treasury,
        fields.required_usdg_raised
      ]
    ])
  end

  defp risk_copy(0),
    do:
      "Your wallet creates this launch on the local Robinhood lab with test assets and no mainnet value. The launch fee is zero."

  defp risk_copy(fee),
    do:
      "Your wallet spends #{usdg_units(fee)} test USDG to create this launch on the local Robinhood lab. The fee is not refunded. Test assets have no mainnet value."

  defp usdg_units(amount), do: Rpc.format_units(amount, @usdg_decimals)

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Stored drafts

  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft(draft_id, actor: actor) do
      {:ok, nil} -> unavailable(:launch_draft_not_found)
      {:ok, %{chain: :robinhood} = draft} -> {:ok, draft}
      {:ok, _other_chain} -> unavailable(:launch_draft_not_found)
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end

  # Everything the launchpad requires of a saved draft, refused here rather than
  # in a wallet. The draft's raise is entered in whole USDG.
  defp launchable(draft) do
    with true <- LaunchDraft.launch_ready?(draft) || unavailable(:launch_metadata_incomplete),
         true <-
           Enum.all?(@metadata, fn {field, limit} ->
             byte_size(Map.fetch!(draft, field)) <= limit
           end) || unavailable(:launch_metadata_incomplete),
         {:ok, treasury} <- address(draft.treasury, :launch_treasury_invalid),
         {:ok, required} <- usdg_atomic(draft.required_regent_raised) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: draft.website,
         image: draft.image,
         treasury: treasury,
         required_usdg_raised: required
       }}
    end
  end

  defp usdg_atomic(value) do
    case Amounts.parse_units(value, @usdg_decimals) do
      {:ok, atomic} -> {:ok, atomic}
      {:error, _reason} -> unavailable(:launch_raise_invalid)
    end
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  # Chain snapshot

  defp robinhood_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:robinhood_unavailable)
    end
  end

  defp snapshot(signer) do
    case LaunchChainClient.snapshot(%{signer: signer}) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
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
               chain: draft.chain,
               envelope: envelope,
               signer: signer,
               step: first_step(envelope)
             }),
           do: {:ok, presented(operation)}
    end)
  end

  defp first_step(envelope),
    do: envelope["arguments"]["steps"] |> hd() |> Map.fetch!("step") |> String.to_existing_atom()

  defp release_undispatched(account_id) do
    case LaunchOperations.open(account_id, true) do
      {:ok, nil} ->
        :ok

      {:ok, %{state: :prepared} = open} ->
        released(LaunchOperations.update(open, :cancel, %{reason: @replaced}))

      {:ok, open} ->
        released(LaunchOperations.update(open, :close_submission_unknown, %{reason: @replaced}))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp released({:ok, _closed}), do: :ok
  defp released(error), do: error

  defp claiming(signer, candidate, fresh) do
    fn account, operation ->
      with :ok <- same_signer(operation, signer),
           :ok <- LaunchOperations.signer_matches(account, operation.signer),
           :ok <- unchanged(operation, candidate) do
        dispatch(operation, valid_envelope?(operation), still_reviewed(operation, fresh))
      end
    end
  end

  defp dispatch(operation, false, _reviewed),
    do: LaunchOperations.update(operation, :invalidate, %{reason: "the reviewed network changed"})

  defp dispatch(operation, true, :ok), do: LaunchOperations.update(operation, :claim_dispatch)

  defp dispatch(operation, true, {:changed, reason}),
    do: LaunchOperations.update(operation, :invalidate, %{reason: reason})

  defp unchanged(operation, candidate) do
    if identity(operation) == identity(candidate), do: :ok, else: unavailable(:launch_step_moved)
  end

  # Everything the review promised about the lab, checked against the lab's
  # answer right now. The correction is still the exact correction it was
  # reviewed as, while the launch is only handed over on an allowance that
  # equals the fee exactly.
  defp still_reviewed(%{step: step} = operation, fresh) do
    cond do
      fresh.paused ->
        {:changed, @paused}

      not Address.equal?(fresh.launchpad, argument(operation, "launchpad")) ->
        {:changed, @moved}

      not Address.equal?(fresh.usdg, argument(operation, "usdg")) ->
        {:changed, @moved}

      fresh.fee != atomic(operation, "expected_launch_fee_atomic") ->
        {:changed, @stale_fee}

      fresh.minimum_raise_usdg != atomic(operation, "minimum_raise_usdg_atomic") ->
        {:changed, @minimum_moved}

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

  defp valid_envelope?(operation) do
    Envelope.valid?(operation.envelope,
      resource: @resource,
      action: @action,
      signer: operation.signer,
      to: argument(operation, "launchpad"),
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    ) and
      Lab.binding_matches?(
        operation.envelope["metadata"]["lab"],
        LaunchChainClient.binding_keys()
      )
  end

  defp transition(action, nil),
    do: fn _account, operation -> LaunchOperations.update(operation, action) end

  defp transition(action, reason),
    do: fn _account, operation ->
      LaunchOperations.update(operation, action, %{reason: reason})
    end

  defp read_chain(%{state: :submitted} = candidate) do
    hash = LaunchOperations.hash(candidate, candidate.step)

    case LaunchChainClient.verify(candidate.envelope, candidate.step, hash) do
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

  defp record(%{step: :approval} = operation, %{outcome: :confirmed} = outcome),
    do: LaunchOperations.update(operation, :advance, %{result: merged(operation, outcome)})

  defp record(operation, %{outcome: :confirmed} = outcome),
    do:
      LaunchOperations.update(operation, :record_chain_verified, %{
        result: merged(operation, outcome)
      })

  defp record(operation, %{outcome: :reverted}),
    do: LaunchOperations.update(operation, :record_revert, %{reason: @reverted})

  defp record(operation, %{outcome: :unverified}),
    do: LaunchOperations.update(operation, :record_unverified, %{reason: @contradicted})

  defp record(operation, _unresolved), do: {:ok, operation}

  defp merged(%{result: result}, outcome), do: Map.merge(result || %{}, outcome[:result] || %{})

  defp expire_lapsed(%{state: :prepared, envelope: %{"expires_at" => expires_at}} = operation) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)

    if DateTime.compare(expires_at, Envelope.current_time()) != :gt,
      do: LaunchOperations.update(operation, :expire, %{reason: @lapsed}),
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

  defp transact(lease, callback), do: LaunchOperations.transact(lease, callback)

  defp operation(account_id, action_id, lock?),
    do: LaunchOperations.fetch(account_id, action_id, lock?)

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

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp atomic(operation, key), do: operation |> argument(key) |> String.to_integer()

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
