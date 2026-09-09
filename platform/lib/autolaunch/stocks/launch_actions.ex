defmodule Autolaunch.Stocks.LaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Stocks launchpad.

  Preparation reads the fork once and writes the whole reviewed sequence as a
  single immutable envelope: at most an exact REGENT allowance correction for the
  launch fee, then the one `launch(LaunchParams)` call it enables, exactly as
  the Agent launch lane does. Every durable write after that runs inside
  `SessionAuthority.transact_lease/3` against the account that callback locked.

  The review derives the executable values from the saved draft and the chain:
  the first bidding block from the zoned start and the current fork block, the
  executable floor price as the largest multiple of 100 not above the entered
  price, the required raise in the admitted STOCK's own base units, and the
  launch fee the launchpad charges right now, which the tuple carries as
  `expectedLaunchFee` so a fee that moves reverts rather than overcharges.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  alias Autolaunch.Stocks.{
    Amounts,
    Assets,
    Lab,
    LabLaunchChainClient,
    LabProjection,
    LaunchDraft,
    LaunchOperations
  }

  @resource "autolaunch_stocks_launch"
  @action "autolaunch_stocks_launch"
  @contract_name "StocksLaunchpadV1"

  # Preset terms the review states back, from contracts/stocks/README.md.
  @new_decimals 18
  @regent_decimals 18
  @auction_duration_blocks 43_200
  @claim_delay_blocks 64
  @migration_delay_blocks 128
  @seconds_per_block 2
  @min_start_lead_seconds 600
  @max_start_lead_seconds 30 * 24 * 3600
  @tick_divisor 100
  @min_floor_price_q96 Integer.pow(2, 32) + 1
  @uint64_max Integer.pow(2, 64) - 1
  @uint128_max Integer.pow(2, 128) - 1
  @zero_address "0x" <> String.duplicate("0", 40)

  @metadata [name: 64, symbol: 16, description: 512, website: 256, image: 256]

  @replaced "replaced by a newer review"
  @rejected "wallet reported an explicit user rejection"
  @withdrawn "review withdrawn"
  @lapsed "the reviewed launch expired before it was sent"
  @unresolved "account started a new launch while this one was unresolved"
  @reverted "verified revert on the local fork"
  @contradicted "canonical receipt contradicts the reviewed launch"
  @paused "launches were paused after this review"
  @moved "the reviewed launchpad binding changed"
  @revoked "this stock token is no longer admitted"
  @subject_moved "the subject revenue address is no longer recognised"
  @stale_fee "the launch fee changed after this review"
  @short "this wallet no longer holds the launch fee"
  @allowance_moved "the REGENT allowance changed after this review"

  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]
  @identity [:state, :step, :envelope, :approval_transaction_hash, :launch_transaction_hash]

  @launch_fee_copy "paid to REGENT staking as rewards, not refunded if the minimum is not raised"

  @doc "The fixed terms every Stocks launch uses, for the review page."
  def terms do
    [
      {"Launch fee", "100,000 REGENT, #{@launch_fee_copy}"},
      {"Token decimals", Integer.to_string(@new_decimals)},
      {"Initial supply", "1,000,000,000 NEW"},
      {"Sold at auction", "800,000,000 NEW (80%)"},
      {"Pool reserve", "200,000,000 NEW (20%)"},
      {"Auction length", "#{@auction_duration_blocks} blocks, about 24 hours"},
      {"Claims open", "#{@claim_delay_blocks} blocks after the auction ends"},
      {"Pool opens", "#{@migration_delay_blocks} blocks after the auction ends"},
      {"Creator allocation", "None"},
      {"Vesting", "None"},
      {"Treasury", "None"},
      {"REGENT revenue lane", "1.00% of stock-side pool volume"},
      {"Subject revenue lane", "Off, or 1.00% when enabled"},
      {"Pool fee", "0.30%"},
      {"Unsold tokens", "Retired to 0x…dEaD after a successful auction"},
      {"Pool liquidity", "Locked forever at 0x…dEaD"},
      {"If the minimum is not raised",
       "Every bid is refundable through the auction; the launch fee is not refunded"}
    ]
  end

  @doc "The launch fee sentence the wallet card states for one reviewed fee, in whole REGENT."
  def launch_fee_copy(fee_units) when is_binary(fee_units),
    do: "#{Amounts.grouped(fee_units)} REGENT, #{@launch_fee_copy}"

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
         {:ok, fields} <- launchable(draft),
         {:ok, config} <- stocks_lab(),
         {:ok, snapshot} <- snapshot(Map.put(fields, :signer, signer)),
         {:ok, executable} <- executable(fields, snapshot, config),
         {:ok, operation} <-
           open(lease, draft, signer, review(draft, fields, executable, signer, snapshot, config)) do
      {:ok, %{operation: operation}}
    end
  end

  @doc "Claims the current step's dispatch after the fork is read again and compared to the review."
  @spec claim_dispatch(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_dispatch(action_id, address, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         {:ok, candidate} <- operation(lease.account_id, action_id, false),
         {:ok, fresh} <- snapshot(reviewed_fields(candidate)) do
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
    |> Autolaunch.WalletAttempts.decorate(operation, :stocks_launch)
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
    with {:ok, fresh} <- snapshot(reviewed_fields(operation)),
         true <- valid_envelope?(operation),
         :ok <- still_reviewed(operation, fresh),
         do: :ok,
         else: (_ -> unavailable(:launch_step_moved))
  end

  # Executable values

  @doc """
  Everything the chain will execute, derived from the saved draft, the admitted
  STOCK's decimals, the launchpad's current fee and the current fork block.
  Exposed so the review page and the envelope test can state exactly the same
  numbers.
  """
  def executable(fields, snapshot, _config) do
    with :ok <- admitted(snapshot),
         {:ok, start_block} <- start_block(fields.start_at, snapshot.block),
         {:ok, floor} <- floor_price(fields.floor_price, snapshot.admission.decimals),
         {:ok, required} <- required_raise(fields.minimum_raise, snapshot.admission.decimals) do
      {:ok,
       %{
         start_block: start_block,
         end_block: start_block + @auction_duration_blocks,
         floor_price_q96: floor.executable,
         floor_price_evidence: floor,
         tick_spacing_q96: div(floor.executable, @tick_divisor),
         required_stock_raised: required,
         stock_decimals: snapshot.admission.decimals,
         subject_splitter: fields.subject_splitter || @zero_address,
         launch_fee: snapshot.fee,
         estimated_end_at:
           DateTime.add(fields.start_at, @auction_duration_blocks * @seconds_per_block, :second)
       }}
    end
  end

  # `startBlock = currentForkBlock + ceil(seconds_until_start / 2)`, refused
  # outside the launchpad's own lead window.
  defp start_block(start_at, %{number: number, timestamp: timestamp}) do
    seconds = DateTime.to_unix(start_at) - timestamp

    cond do
      seconds < @min_start_lead_seconds ->
        unavailable(:start_too_soon)

      seconds > @max_start_lead_seconds ->
        unavailable(:start_too_late)

      true ->
        bounded(
          number + div(seconds + @seconds_per_block - 1, @seconds_per_block),
          @uint64_max,
          :start_too_late
        )
    end
  end

  # The largest multiple of 100 not above the entered price, so the executable
  # floor never exceeds what the creator typed, and never below the CCA minimum.
  defp floor_price(value, decimals) do
    with {:ok, evidence} <- Amounts.cca_price(value, decimals, @new_decimals) |> refusable(),
         executable <-
           evidence.candidate_price_q96 - rem(evidence.candidate_price_q96, @tick_divisor),
         true <- executable >= @min_floor_price_q96 || unavailable(:floor_price_too_low) do
      {:ok,
       Map.merge(evidence, %{
         executable: executable,
         executable_stock_per_new: Amounts.format_cca_price(executable, decimals, @new_decimals)
       })}
    end
  end

  defp required_raise(value, decimals) do
    with {:ok, raw} <- Amounts.parse_units(value, decimals) |> refusable(),
         do: bounded(raw, @uint128_max, :minimum_raise_unrepresentable)
  end

  defp bounded(value, max, _reason) when value > 0 and value <= max, do: {:ok, value}
  defp bounded(_value, _max, reason), do: unavailable(reason)

  defp admitted(%{paused: true}), do: unavailable(:launches_paused)
  defp admitted(%{admission: %{admitted: false}}), do: unavailable(:stock_not_admitted)
  defp admitted(%{subject: :unverified}), do: unavailable(:subject_splitter_unrecognised)

  defp admitted(%{balance: balance, fee: fee}) when balance < fee,
    do: unavailable(:insufficient_regent)

  defp admitted(_snapshot), do: :ok

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
        "stock" => fields.stock,
        "stock_symbol" => fields.stock_symbol,
        "stock_decimals" => Integer.to_string(executable.stock_decimals),
        "start_at" => DateTime.to_iso8601(fields.start_at),
        "start_timezone" => fields.start_timezone,
        "start_block" => Integer.to_string(executable.start_block),
        "end_block" => Integer.to_string(executable.end_block),
        "estimated_end_at" => DateTime.to_iso8601(executable.estimated_end_at),
        "minimum_raise" => draft.minimum_raise,
        "required_stock_raised" => Integer.to_string(executable.required_stock_raised),
        "floor_price_entered" => draft.floor_price,
        "floor_price_q96" => Integer.to_string(executable.floor_price_q96),
        "floor_price_executable" => executable.floor_price_evidence.executable_stock_per_new,
        "floor_price_adjusted" =>
          executable.floor_price_evidence.adjustment_required or
            executable.floor_price_evidence.candidate_price_q96 != executable.floor_price_q96,
        "tick_spacing_q96" => Integer.to_string(executable.tick_spacing_q96),
        "fee_administrator" => fields.fee_administrator,
        "subject_enabled" => fields.subject_splitter != nil,
        "subject_splitter" => executable.subject_splitter,
        "expected_launch_fee_atomic" => Integer.to_string(snapshot.fee),
        "expected_launch_fee" => regent_units(snapshot.fee),
        "allowance_atomic" => Integer.to_string(snapshot.allowance),
        "regent" => snapshot.regent,
        "launchpad" => snapshot.launchpad,
        "hook" => snapshot.hook,
        "route" => snapshot.admission.route,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "block_timestamp" => snapshot.block.timestamp,
        "terms" => Enum.map(terms(), fn {label, value} -> [label, value] end),
        "steps" => steps
      }
    )
    |> stored()
  end

  @doc """
  The reviewed sequence: the exact allowance correction when the standing
  allowance is not already the fee, then the one `launch` call it enables.

  The launchpad requires the allowance to equal the fee exactly, zero included,
  so an allowance that is higher is corrected down just as a lower one is
  corrected up. There is no additive approval and no unlimited approval.
  """
  def reviewed_steps(fields, executable, snapshot, config) do
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

  defp approval_step(%{regent: regent, launchpad: launchpad, fee: fee}, config) do
    [
      %{
        "step" => "approval",
        "to" => regent,
        "data" =>
          LabAbi.encode(Lab.abi!(config, :erc20), "approve(address,uint256)", [launchpad, fee]),
        "amount" => Integer.to_string(fee),
        "spender" => launchpad
      }
    ]
  end

  @doc "The exact `launch(LaunchParams)` calldata for reviewed fields and executable values."
  def launch_data(fields, executable, config) do
    LabAbi.encode(Lab.abi!(config, :launchpad), StocksLabAbi.launch_signature(), [
      [
        fields.name,
        fields.symbol,
        fields.description,
        fields.website,
        fields.image,
        fields.stock,
        executable.start_block,
        executable.floor_price_q96,
        executable.required_stock_raised,
        fields.fee_administrator,
        executable.subject_splitter,
        executable.launch_fee
      ]
    ])
  end

  defp risk_copy(0),
    do:
      "Your wallet creates this launch on a local Base fork with test assets and no mainnet value. The launch fee is zero."

  defp risk_copy(fee),
    do:
      "Your wallet spends #{regent_units(fee)} forked REGENT to create this launch on a local Base fork. The fee goes to REGENT staking and is not refunded. Test assets have no mainnet value."

  defp regent_units(amount), do: Rpc.format_units(amount, @regent_decimals)

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Stored drafts

  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_stocks_launch_draft_by_id(draft_id, actor: actor) do
      {:ok, nil} -> unavailable(:launch_draft_not_found)
      {:ok, draft} -> {:ok, draft}
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end

  @doc "Everything the launchpad requires of a saved draft, refused here rather than in a wallet."
  def launchable(draft) do
    with true <-
           LaunchDraft.token_details_complete?(draft) || unavailable(:launch_metadata_incomplete),
         true <-
           Enum.all?(@metadata, fn {field, limit} ->
             byte_size(Map.fetch!(draft, field)) <= limit
           end) || unavailable(:launch_metadata_incomplete),
         {:ok, asset} <-
           Assets.fetch(draft.stock_chain_id, draft.stock_address || "") |> refusable(),
         {:ok, stock} <- address(asset.address, :stock_invalid),
         %DateTime{} = start_at <- draft.start_at || unavailable(:start_missing),
         true <- LaunchDraft.timezone?(draft.start_timezone) || unavailable(:start_missing),
         true <- is_binary(draft.minimum_raise) || unavailable(:minimum_raise_missing),
         true <- is_binary(draft.floor_price) || unavailable(:floor_price_missing),
         {:ok, fee_administrator} <- address(draft.fee_administrator, :fee_administrator_invalid),
         {:ok, subject_splitter} <- subject_splitter(draft) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: draft.website,
         image: draft.image,
         stock: stock,
         stock_symbol: asset.symbol,
         start_at: start_at,
         start_timezone: draft.start_timezone,
         minimum_raise: draft.minimum_raise,
         floor_price: draft.floor_price,
         fee_administrator: fee_administrator,
         subject_splitter: subject_splitter
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  # The lane is off unless it was switched on, and then only an address will do.
  # Disabling the lane leaves no splitter anywhere in the executable params.
  defp subject_splitter(%{subject_enabled: false}), do: {:ok, nil}

  defp subject_splitter(%{subject_enabled: true, subject_splitter: value}),
    do: address(value, :subject_splitter_invalid)

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  # Chain snapshot

  defp stocks_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:stocks_unavailable)
    end
  end

  defp snapshot(%{stock: stock, subject_splitter: candidate, signer: signer}) do
    case LabLaunchChainClient.snapshot(%{
           stock: stock,
           subject_splitter: candidate,
           signer: signer
         }) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp reviewed_fields(operation) do
    %{
      stock: argument(operation, "stock"),
      subject_splitter:
        if(argument(operation, "subject_enabled"), do: argument(operation, "subject_splitter")),
      signer: operation.signer
    }
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

  # Everything the review promised about the fork, checked against the fork's
  # answer right now. The allowance rule differs by step on purpose: the
  # correction is still the exact correction it was reviewed as, while the launch
  # is only ever handed over on an allowance that equals the fee exactly.
  defp still_reviewed(%{step: step} = operation, fresh) do
    cond do
      fresh.paused ->
        {:changed, @paused}

      not Address.equal?(fresh.launchpad, argument(operation, "launchpad")) ->
        {:changed, @moved}

      not Address.equal?(fresh.regent, argument(operation, "regent")) ->
        {:changed, @moved}

      not fresh.admission.admitted ->
        {:changed, @revoked}

      Integer.to_string(fresh.admission.decimals) != argument(operation, "stock_decimals") ->
        {:changed, @revoked}

      fresh.subject == :unverified ->
        {:changed, @subject_moved}

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
        LabLaunchChainClient.binding_keys()
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

    case LabLaunchChainClient.verify(candidate.envelope, candidate.step, hash) do
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

  # A verified allowance correction makes the launch sendable; the approval's own
  # hash stays exactly where it is.
  defp record(%{step: :approval} = operation, %{outcome: :confirmed} = outcome),
    do: LaunchOperations.update(operation, :advance, %{result: merged(operation, outcome)})

  defp record(operation, %{outcome: :confirmed} = outcome) do
    with :ok <- LabProjection.project_launch(operation, outcome[:result] || %{}) do
      LaunchOperations.update(operation, :record_chain_verified, %{
        result: merged(operation, outcome)
      })
    end
  end

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

  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp atomic(operation, key), do: operation |> argument(key) |> String.to_integer()

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
