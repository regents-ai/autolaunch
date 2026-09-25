defmodule Autolaunch.Robinhood.StocksLaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Robinhood Stocks launchpad.

  Preparation reads the local Robinhood lab once and returns the whole reviewed
  sequence as a single immutable envelope: the one `launch(LaunchParams)` call.
  The review is stored (`Autolaunch.Robinhood.LaunchReview`) so the market feed
  can tell this site's launches from launches seen only on chain. Confirmation
  reads the canonical receipt through
  `Autolaunch.Robinhood.StocksLaunchChainClient`, and a wallet's launches are the
  launchpad's own `StockLaunchCreated` records for that wallet.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time: the wallet the page presents must
  be exactly that wallet, never another linked address.

  The review derives the executable values from the saved Robinhood draft and
  the chain: the required raise the creator entered, in the admitted STOCK's
  base units, and the executable floor price as the largest multiple of 100 not
  above the entered price. Bidding opens a fixed number of blocks after the
  block the launch is created in, so the receipt is the only source of the
  start and end blocks.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LaunchChain}
  alias Autolaunch.Robinhood.{Lab, StocksLaunchChainClient}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchDraft, LaunchOperations}

  @resource "autolaunch_robinhood_stocks_launch"
  @action "autolaunch_robinhood_stocks_launch"
  @contract_name "RobinhoodStocksLaunchpadV1"

  # Preset terms the review states back, from contracts/robinhood/src/RobinhoodPreset.sol.
  @new_decimals 18
  @start_lead_blocks 6_000
  @auction_duration_blocks 864_000
  @claim_delay_blocks 1_280
  @migration_delay_blocks 2_560
  @tick_divisor 100
  @min_floor_price_q96 Integer.pow(2, 32) + 1
  @uint128_max Integer.pow(2, 128) - 1
  @lifecycles %{0 => "none", 1 => "active", 2 => "graduated", 3 => "failed"}

  @metadata [name: 64, symbol: 16, description: 512, image: 256]
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc "The fixed terms every Robinhood Stocks launch uses, for the review page, in the ticker of the token it creates."
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
      {"Pool pair", "#{ticker} and the stock it was launched against"},
      {"Staker revenue lane", "1% of stock-side volume to the token's stakers, always on"},
      {"Unsold tokens", "Retired to 0x…dEaD after a successful auction"},
      {"Pool liquidity", "Locked forever in the fee locker; its trading fees go to stakers"},
      {"If the required raise is not reached", "Every bid is refundable through the auction"}
    ]
  end

  @doc "How long the schedule's parts take, as blocks with an estimated duration."
  def schedule_copy(blocks),
    do:
      "#{Amounts.grouped(Integer.to_string(blocks))} blocks, #{LaunchChain.time_estimate(:robinhood, blocks)}"

  def start_lead_blocks, do: @start_lead_blocks
  def auction_duration_blocks, do: @auction_duration_blocks

  @doc """
  Reviews one saved Robinhood draft for the signed-in wallet: one snapshot, one
  immutable envelope, the reviewed steps and the plain facts the page shows.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(draft_id, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, draft} <- owned_draft(draft_id, actor),
         {:ok, fields} <- launchable(draft),
         {:ok, config} <- robinhood_lab(),
         {:ok, snapshot} <- snapshot(fields.stock),
         {:ok, executable} <- executable(fields, snapshot),
         {:ok, _review} <- record_review(actor, signer, fields, executable),
         do: {:ok, build(draft, fields, executable, signer, snapshot, config)}
  end

  # The launch this review would carry out, kept so the market feed knows it
  # as this site's launch whether or not the browser reports it back.
  defp record_review(%Human{human_account_id: account_id}, signer, fields, executable),
    do:
      Autolaunch.record_robinhood_launch_review(
        %{
          chain_id: Lab.chain_id(),
          signer: String.downcase(signer),
          human_account_id: account_id,
          name: fields.name,
          symbol: fields.symbol,
          stock: String.downcase(fields.stock),
          telegram: fields.telegram,
          required_stock_raised: Integer.to_string(executable.required_stock_raised),
          floor_price_q96: Integer.to_string(executable.floor_price_q96)
        },
        actor: %Autolaunch.Actors.System{}
      )

  @doc """
  Reads the sent launch back from the chain for the signed-in wallet. The
  result is the chain client's own answer: `:pending`, `:reverted`,
  `:unverified`, or `:confirmed` with the launchpad's record of the launch.
  """
  @spec verify(map(), :launch, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(envelope, :launch, hash, opts) when is_map(envelope) do
    with {:ok, actor} <- human(opts),
         {:ok, _signer} <- current_wallet(envelope["expected_signer"], actor, opts),
         {:ok, hash} <- canonical_hash(hash),
         {:ok, config} <- robinhood_lab(),
         true <- valid_envelope?(envelope, config) || unavailable(:envelope_invalid),
         do: read_chain(envelope, hash)
  end

  def verify(_envelope, _step, _hash, _opts), do: unavailable(:unknown_step)

  @doc """
  Every launch the launchpad records for the signed-in wallet, read at one
  pinned block: the `StockLaunchCreated` logs for that launcher from the chain's
  first block to the pinned block, each confirmed against `launches(launchId)`
  at the same block. A malformed log or a record that does not name the wallet
  refuses the whole read rather than dropping an entry.
  """
  @spec launches(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def launches(address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, config} <- robinhood_lab(),
         rpc <- Lab.rpc_opts(config),
         {:ok, block} <- chain(Rpc.latest_block(rpc)),
         {:ok, logs} <- launch_logs(signer, block, config, rpc),
         {:ok, launches} <- launch_records(logs, signer, block, config, rpc) do
      {:ok, %{block: block, launches: launches}}
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
         website: LaunchDraft.onchain_website(draft),
         telegram: draft.telegram,
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

  # Executable values

  defp executable(fields, snapshot) do
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

  defp admitted(%{paused: true}), do: unavailable(:launches_paused)
  defp admitted(%{admission: %{admitted: false}}), do: unavailable(:stock_not_admitted)
  defp admitted(_snapshot), do: :ok

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

  # The review

  defp build(draft, fields, executable, signer, snapshot, config) do
    steps = reviewed_steps(fields, executable, snapshot, config)
    data = steps |> List.last() |> Map.fetch!("data")

    envelope =
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
          "telegram" => fields.telegram,
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
          "floor_price_adjusted" => floor_adjusted?(executable),
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

    %{envelope: envelope, steps: steps, review: review(fields, executable)}
  end

  # The plain facts the page shows before anything is signed.
  defp review(fields, executable) do
    [
      ["Launch fee", "None"],
      [
        "Required raise",
        "#{Amounts.grouped(Rpc.format_units(executable.required_stock_raised, executable.stock_decimals))} #{fields.stock_symbol}"
      ],
      ["Bidding opens", "#{schedule_copy(@start_lead_blocks)} after the launch is created"],
      ["Auction length", schedule_copy(@auction_duration_blocks)],
      ["Floor price", floor_copy(fields, executable)]
    ]
  end

  # The page shows a readable price; the envelope keeps the exact one.
  defp floor_copy(fields, executable) do
    executable_price =
      "#{Amounts.compact_decimal(executable.floor_price_evidence.executable_stock_per_new)} #{fields.stock_symbol} per NEW"

    if floor_adjusted?(executable),
      do: "#{executable_price}, adjusted down from the #{fields.floor_price} you entered",
      else: executable_price
  end

  defp floor_adjusted?(executable) do
    executable.floor_price_evidence.adjustment_required or
      executable.floor_price_evidence.candidate_price_q96 != executable.floor_price_q96
  end

  # The reviewed sequence: the one `launch` call.
  defp reviewed_steps(fields, executable, snapshot, config) do
    [
      %{
        "step" => "launch",
        "to" => snapshot.launchpad,
        "data" => launch_data(fields, executable, config)
      }
    ]
  end

  defp launch_data(fields, executable, config) do
    LabAbi.encode(
      Lab.abi!(config, :stocks_launchpad),
      RobinhoodLabAbi.stocks_launch_signature(),
      [
        [
          [
            fields.name,
            fields.symbol,
            fields.description,
            fields.website,
            fields.image,
            executable.floor_price_q96
          ],
          fields.stock,
          executable.required_stock_raised
        ]
      ]
    )
  end

  defp risk_copy do
    network =
      if Lab.test_chain?(),
        do: "the local Robinhood lab with test assets and no mainnet value",
        else: "Robinhood Chain (chain #{Lab.chain_id()})"

    "Your wallet creates this launch on #{network}. There is no launch fee."
  end

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Confirmation

  # The expected target is the current lab's launchpad, never a field of the
  # envelope under review.
  defp valid_envelope?(envelope, config) do
    Envelope.valid_for_confirmation?(envelope,
      resource: @resource,
      action: @action,
      signer: envelope["expected_signer"],
      to: Lab.address!(config, :stocks_launchpad),
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    )
  end

  defp read_chain(envelope, hash) do
    case StocksLaunchChainClient.verify(envelope, :launch, hash) do
      {:ok, result} -> {:ok, result}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # A wallet's launches, from the launchpad's own records

  defp launch_logs(signer, block, config, rpc) do
    launchpad = Lab.address!(config, :stocks_launchpad)
    topic = LabAbi.topic(RobinhoodLabAbi.stock_launch_created_signature())

    filter = %{
      address: launchpad,
      fromBlock: "0x0",
      toBlock: quantity(block.number),
      topics: [topic, nil, topic_address(signer)]
    }

    case Rpc.request("eth_getLogs", [filter], rpc) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> unavailable(:invalid_chain_response)
      {:error, reason} -> chain({:error, reason})
    end
  end

  defp launch_records(logs, signer, block, config, rpc) do
    launchpad = Lab.address!(config, :stocks_launchpad)
    abi = Lab.abi!(config, :stocks_launchpad)

    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, launches} ->
      with {:ok, created} <- launch_created(abi, log, launchpad, signer),
           {:ok, record} <-
             Rpc.call_words(
               launchpad,
               LabAbi.encode(abi, "launches(uint256)", [created.launch_id]),
               block,
               RobinhoodLabAbi.launch_record_words(),
               rpc
             ),
           {:ok, launch} <- launch_record(created, record) do
        {:cont, {:ok, [launch | launches]}}
      else
        {:error, :chain_unavailable} -> {:halt, unavailable(:chain_unavailable)}
        _malformed -> {:halt, unavailable(:invalid_chain_response)}
      end
    end)
    |> case do
      {:ok, launches} -> {:ok, Enum.reverse(launches)}
      error -> error
    end
  end

  # The immutable facts one `StockLaunchCreated` log announced, refused unless
  # the launcher is the signed-in wallet.
  defp launch_created(abi, log, launchpad, signer) do
    with {:ok,
          {[launch_id, launcher_word, new_token_word],
           [
             stock_word,
             auction_word,
             start_block,
             end_block,
             floor_price_q96,
             required_raise,
             _auction_inventory,
             _migration_reserve
           ]}} <-
           LabAbi.event_words(
             abi,
             RobinhoodLabAbi.stock_launch_created_signature(),
             [log],
             launchpad
           ),
         {:ok, launcher} <- Abi.word_address(launcher_word),
         true <- Address.equal?(launcher, signer),
         {:ok, new_token} <- Abi.word_address(new_token_word),
         {:ok, stock} <- Abi.word_address(stock_word),
         {:ok, auction} <- Abi.word_address(auction_word) do
      {:ok,
       %{
         launch_id: launch_id,
         launcher: launcher,
         new_token: new_token,
         stock: stock,
         auction: auction,
         start_block: start_block,
         end_block: end_block,
         floor_price_q96: floor_price_q96,
         required_raise: required_raise
       }}
    else
      _ -> :error
    end
  end

  # `launches(launchId)`: launcher, newToken, currency (the STOCK), auction,
  # startBlock, endBlock, claimBlock, migrationBlock, requiredRaise,
  # floorPriceQ96, lifecycle, ... Every fact the event announced must be
  # repeated by the record; only the later blocks and the lifecycle are new.
  defp launch_record(
         created,
         [
           launcher_word,
           new_token_word,
           currency_word,
           auction_word,
           start_block,
           end_block,
           claim_block,
           migration_block,
           required_raise,
           floor_price_q96,
           lifecycle | _rest
         ]
       ) do
    with {:ok, launcher} <- Abi.word_address(launcher_word),
         {:ok, new_token} <- Abi.word_address(new_token_word),
         {:ok, stock} <- Abi.word_address(currency_word),
         {:ok, auction} <- Abi.word_address(auction_word),
         true <-
           Address.equal?(launcher, created.launcher) and
             Address.equal?(new_token, created.new_token) and
             Address.equal?(stock, created.stock) and
             Address.equal?(auction, created.auction) and
             start_block == created.start_block and
             end_block == created.end_block and
             required_raise == created.required_raise and
             floor_price_q96 == created.floor_price_q96,
         {:ok, lifecycle} <- Map.fetch(@lifecycles, lifecycle) do
      {:ok,
       %{
         "launch_id" => Integer.to_string(created.launch_id),
         "launcher" => launcher,
         "new_token" => new_token,
         "stock" => stock,
         "auction" => auction,
         "start_block" => Integer.to_string(start_block),
         "end_block" => Integer.to_string(end_block),
         "claim_block" => Integer.to_string(claim_block),
         "migration_block" => Integer.to_string(migration_block),
         "required_stock_raised" => Integer.to_string(required_raise),
         "floor_price_q96" => Integer.to_string(floor_price_q96),
         "lifecycle" => lifecycle
       }}
    else
      _ -> :error
    end
  end

  defp launch_record(_created, _record), do: :error

  defp topic_address("0x" <> hex), do: "0x" <> String.pad_leading(hex, 64, "0")

  defp quantity(number), do: "0x" <> Integer.to_string(number, 16)

  # Chain snapshot

  defp robinhood_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:robinhood_unavailable)
    end
  end

  defp snapshot(stock), do: chain(StocksLaunchChainClient.snapshot(%{stock: stock}))

  defp chain({:ok, value}), do: {:ok, value}
  defp chain({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  defp chain({:error, reason}), do: unavailable(reason)

  # Stored drafts

  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_stocks_launch_draft_by_id(draft_id, actor: actor) do
      {:ok, %{chain: :robinhood} = draft} -> {:ok, draft}
      {:ok, _other} -> unavailable(:launch_draft_not_found)
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
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

  # The wallet the page presents has to be the signed-in wallet of the leased
  # account, read now: not another linked address, and never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address, :invalid_address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: signed_in_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp signed_in_wallet(%{wallet_address: wallet}, candidate) when is_binary(wallet) do
    if Address.equal?(wallet, candidate), do: {:ok, candidate}, else: unavailable(:wrong_signer)
  end

  defp signed_in_wallet(_account, _candidate), do: unavailable(:wrong_signer)

  # Shared helpers

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
