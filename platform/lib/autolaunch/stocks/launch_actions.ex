defmodule Autolaunch.Stocks.LaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Stocks launchpad.

  Preparation reads the fork once and writes the whole reviewed sequence as a
  single immutable envelope: the one `launch(LaunchParams)` call. Every durable
  write after that runs inside `SessionAuthority.transact_lease/3` against the
  account that callback locked. Wallet presses of the review are
  `Autolaunch.WalletAttempts`; this module only supplies their evidence.

  The review derives the executable values from the saved draft and the chain:
  the required raise the creator entered, in the admitted STOCK's base units,
  and the executable floor price as the largest multiple of 100 not above the
  entered price. Bidding opens a fixed number of blocks after the block the
  launch is created in, so the schedule is the launchpad's own and the receipt
  is the only source of the start and end blocks.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LaunchChain}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  alias Autolaunch.Stocks.{
    Amounts,
    Assets,
    Lab,
    LabLaunchChainClient,
    LaunchDraft,
    LaunchOperations
  }

  @resource "autolaunch_stocks_launch"
  @action "autolaunch_stocks_launch"
  @contract_name "StocksLaunchpadV1"

  # Preset terms the review states back, from contracts/stocks/README.md.
  @new_decimals 18
  @start_lead_blocks 300
  @auction_duration_blocks 43_200
  @claim_delay_blocks 64
  @migration_delay_blocks 128
  @tick_divisor 100
  @min_floor_price_q96 Integer.pow(2, 32) + 1
  @uint128_max Integer.pow(2, 128) - 1

  @metadata [name: 64, symbol: 16, description: 512, website: 256, image: 256]

  @withdrawn "review withdrawn"
  @lapsed "the reviewed launch expired before it was sent"
  @unresolved "account started a new launch while this one was unresolved"
  @paused "launches were paused after this review"
  @moved "the reviewed launchpad binding changed"
  @revoked "this stock token is no longer admitted"

  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc "The fixed terms every Stocks launch uses, for the review page, in the ticker of the token it creates."
  def terms(ticker) do
    [
      {"Launch fee", "None"},
      {"Token decimals", Integer.to_string(@new_decimals)},
      {"Initial supply", "1,000,000,000 #{ticker}"},
      {"Sold at auction", "800,000,000 #{ticker} (80%)"},
      {"Pool reserve", "200,000,000 #{ticker} (20%)"},
      {"Bidding opens", "#{schedule_copy(@start_lead_blocks)} after the launch is created"},
      {"Auction length", schedule_copy(@auction_duration_blocks)},
      {"Claims open", "#{schedule_copy(@claim_delay_blocks)} after the auction ends"},
      {"Pool opens", "#{schedule_copy(@migration_delay_blocks)} after the auction ends"},
      {"Creator allocation", "None"},
      {"Vesting", "None"},
      {"Treasury", "None"},
      {"REGENT revenue lane", "1.00% of stock-side pool volume"},
      {"Staker revenue lane",
       "1.00% of stock-side pool volume to the token's stakers, always on"},
      {"Pool fee", "0.30%"},
      {"Unsold tokens", "Retired to 0x…dEaD after a successful auction"},
      {"Pool liquidity", "Locked forever in the fee locker; its trading fees go to stakers"},
      {"If the required raise is not reached", "Every bid is refundable through the auction"}
    ]
  end

  @doc "How long the schedule's parts take, as blocks with an estimated duration."
  def schedule_copy(blocks),
    do:
      "#{Amounts.grouped(Integer.to_string(blocks))} blocks, #{LaunchChain.time_estimate(:base, blocks)}"

  def start_lead_blocks, do: @start_lead_blocks
  def auction_duration_blocks, do: @auction_duration_blocks

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
         {:ok, snapshot} <- snapshot(fields),
         {:ok, executable} <- executable(fields, snapshot, config),
         {:ok, operation} <-
           open(lease, draft, signer, review(draft, fields, executable, signer, snapshot, config)) do
      {:ok, %{operation: operation}}
    end
  end

  def cancel(action_id, opts), do: write(action_id, opts, transition(:cancel, @withdrawn))

  @doc "Ends a launch whose presses have not resolved, at the account's request; nothing is resent."
  def start_new(action_id, opts),
    do: write(action_id, opts, transition(:cancel, @unresolved))

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
      :terminal_at
    ])
    |> Autolaunch.WalletAttempts.decorate(operation, :stocks_launch)
  end

  @doc "The reviewed sequence, in order, as the progress list renders it."
  def steps(%{envelope: envelope}), do: envelope["arguments"]["steps"]

  def step_hash(operation, step) when step in [:launch, "launch"],
    do: Map.get(operation, :launch_transaction_hash)

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
  Everything the chain will execute, derived from the saved draft and the
  admitted STOCK's decimals. Exposed so the review page and the envelope test
  can state exactly the same numbers.
  """
  def executable(fields, snapshot, _config) do
    with :ok <- admitted(snapshot),
         {:ok, floor} <- floor_price(fields.floor_price, snapshot.admission.decimals),
         {:ok, required} <- required_raise(fields.required_raise, snapshot.admission.decimals) do
      {:ok,
       %{
         floor_price_q96: floor.executable,
         floor_price_evidence: floor,
         tick_spacing_q96: div(floor.executable, @tick_divisor),
         required_stock_raised: required,
         stock_decimals: snapshot.admission.decimals
       }}
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

  # The entered raise in the STOCK's base units, exact or refused. The
  # launchpad refuses a raise of nothing or more than the auction can reach.
  defp required_raise(value, decimals) do
    case Amounts.parse_units(value, decimals) do
      {:ok, raw} when raw > 0 and raw <= @uint128_max -> {:ok, raw}
      _invalid -> unavailable(:required_raise_invalid)
    end
  end

  defp admitted(%{paused: true}), do: unavailable(:launches_paused)
  defp admitted(%{admission: %{admitted: false}}), do: unavailable(:stock_not_admitted)
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
      risk_copy: risk_copy(),
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
        "start_lead_blocks" => Integer.to_string(@start_lead_blocks),
        "auction_duration_blocks" => Integer.to_string(@auction_duration_blocks),
        "required_raise_entered" => draft.required_raise,
        "required_stock_raised" => Integer.to_string(executable.required_stock_raised),
        "required_stock_raised_units" =>
          Rpc.format_units(executable.required_stock_raised, executable.stock_decimals),
        "floor_price_entered" => draft.floor_price,
        "floor_price_q96" => Integer.to_string(executable.floor_price_q96),
        "floor_price_executable" => executable.floor_price_evidence.executable_stock_per_new,
        "floor_price_adjusted" =>
          executable.floor_price_evidence.adjustment_required or
            executable.floor_price_evidence.candidate_price_q96 != executable.floor_price_q96,
        "tick_spacing_q96" => Integer.to_string(executable.tick_spacing_q96),
        "launchpad" => snapshot.launchpad,
        "hook" => snapshot.hook,
        "route" => snapshot.admission.route,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "terms" => Enum.map(terms(fields.symbol), fn {label, value} -> [label, value] end),
        "steps" => steps
      }
    )
    |> stored()
  end

  @doc "The reviewed sequence: the one `launch` call."
  def reviewed_steps(fields, executable, snapshot, config) do
    [
      %{
        "step" => "launch",
        "to" => snapshot.launchpad,
        "data" => launch_data(fields, executable, config)
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
        executable.floor_price_q96,
        executable.required_stock_raised
      ]
    ])
  end

  defp risk_copy do
    if Autolaunch.Lab.test_chain?(),
      do:
        "Your wallet creates this launch on a Base fork with test assets and no mainnet value. There is no launch fee.",
      else:
        "Your wallet creates this launch on Base. There is no launch fee. A launch cannot be undone."
  end

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Stored drafts

  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_stocks_launch_draft_by_id(draft_id, actor: actor) do
      {:ok, %{chain: :base} = draft} -> {:ok, draft}
      {:ok, _missing_or_other_chain} -> unavailable(:launch_draft_not_found)
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
         true <- is_binary(draft.required_raise) || unavailable(:required_raise_missing),
         true <- is_binary(draft.floor_price) || unavailable(:floor_price_missing) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: draft.website,
         image: draft.image,
         stock: stock,
         stock_symbol: asset.symbol,
         required_raise: draft.required_raise,
         floor_price: draft.floor_price
       }}
    else
      {:error, _reason} = error -> error
    end
  end

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

  defp snapshot(%{stock: stock}) do
    case LabLaunchChainClient.snapshot(%{stock: stock}) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp reviewed_fields(operation), do: %{stock: argument(operation, "stock")}

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

  # Everything the review promised about the fork, checked against the fork's
  # answer right now.
  defp still_reviewed(operation, fresh) do
    cond do
      fresh.paused ->
        {:changed, @paused}

      not Address.equal?(fresh.launchpad, argument(operation, "launchpad")) ->
        {:changed, @moved}

      not fresh.admission.admitted ->
        {:changed, @revoked}

      Integer.to_string(fresh.admission.decimals) != argument(operation, "stock_decimals") ->
        {:changed, @revoked}

      true ->
        :ok
    end
  end

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

  defp transition(action, reason),
    do: fn _account, operation ->
      LaunchOperations.update(operation, action, %{reason: reason})
    end

  defp expire_lapsed(%{state: :prepared, envelope: %{"expires_at" => expires_at}} = operation) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)

    if DateTime.compare(expires_at, Envelope.current_time()) != :gt and
         not Autolaunch.WalletAttempts.in_flight?(:stocks_launch, operation),
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

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
