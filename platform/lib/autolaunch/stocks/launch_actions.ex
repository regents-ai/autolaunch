defmodule Autolaunch.Stocks.LaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Stocks launchpad.

  Preparation reads the chain once and saves the review
  (`Autolaunch.Stocks.LaunchOperation`): the one `launch(LaunchParams)` step for
  the wallet that may act, and the facts the page shows. The page sends that
  step as it stands; nothing about a press is stored, and
  `Autolaunch.LaunchReviews` lists the launch from the chain. The row write runs
  inside `SessionAuthority.transact_lease/3` against the account that callback
  locked.

  Every launch opens at the lowest price the auction accepts, and its minimum
  raise is the whole sale at that price, as the launchpad derives it. The
  creator chooses neither. Bidding opens a fixed number of blocks after the
  block the launch is created in, so the schedule is the launchpad's own and
  the receipt is the only source of the start and end blocks.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Client, Rpc}
  alias Autolaunch.{LabAbi, LaunchChain, LaunchLinks}
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.{Address, Review}

  alias Autolaunch.Stocks.{
    Amounts,
    Assets,
    FeeSchedule,
    Lab,
    LabLaunchChainClient,
    LaunchDraft,
    LaunchOperations
  }

  # Preset terms the review states back, from contracts/stocks-v2/src/StocksPreset.sol.
  @new_decimals 18
  @auction_inventory 495_000_000 * Integer.pow(10, 18)
  @start_lead_blocks 300
  @auction_duration_blocks 43_200
  @claim_delay_blocks 64
  @migration_delay_blocks 128
  @creator_vesting_blocks 1_296_000
  @tick_divisor 100
  # The auction's lowest floor, 2^32 + 1, rounded up to the next multiple of
  # the tick divisor so the bid tick spacing divides it exactly.
  @floor_price_q96 4_294_967_300
  @q96 Integer.pow(2, 96)

  @metadata [name: 64, symbol: 16, description: 512, image: 256]

  @withdrawn "review withdrawn"

  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc "The fixed terms every Stocks launch uses, for the review page, in the ticker of the token it creates."
  def terms(ticker) do
    [
      {"Launch fee", "None"},
      {"Token decimals", Integer.to_string(@new_decimals)},
      {"Initial supply", "1,000,000,000 #{ticker}"},
      {"Sold at auction", "495,000,000 #{ticker} (49.5%)"},
      {"Pool reserve", "495,000,000 #{ticker} (49.5%)"},
      {"Starting price", "The lowest the auction accepts"},
      {"Minimum raise", "The whole sale at the starting price, a small fraction of one share"},
      {"Bidding opens", "#{schedule_copy(@start_lead_blocks)} after the launch is created"},
      {"Auction length", schedule_copy(@auction_duration_blocks)},
      {"Claims open", "#{schedule_copy(@claim_delay_blocks)} after the auction ends"},
      {"Pool opens", "#{schedule_copy(@migration_delay_blocks)} after the auction ends"},
      {"Creator allocation", "10,000,000 #{ticker} (1%)"},
      {"Vesting",
       "Released block by block over #{schedule_copy(@creator_vesting_blocks)} from the pool opening; anyone can release it and it always goes to the creator"},
      {"Treasury", "None"}
    ] ++
      FeeSchedule.terms(:base) ++
      [
        {"Unsold tokens", "Burned"},
        {"Pool liquidity",
         "Opens at the auction's final price with the whole raise and the reserve it matches; the rest of the reserve is a second position holding only #{ticker}. Both are locked forever and their trading fees go to stakers"},
        {"If the minimum raise is not reached",
         "Every bidder takes back their full bid and every token is burned"}
      ]
  end

  @doc "How long the schedule's parts take, as blocks with an estimated duration."
  def schedule_copy(blocks),
    do:
      "#{Amounts.grouped(Integer.to_string(blocks))} blocks, #{LaunchChain.time_estimate(:base, blocks)}"

  def start_lead_blocks, do: @start_lead_blocks
  def auction_duration_blocks, do: @auction_duration_blocks

  @doc """
  The launch's fixed schedule in blocks: bidding opens `opens` after the
  launch, runs for `length`, and claims and the trading pool open `claim` and
  `pool` after bidding ends.
  """
  def schedule,
    do: %{
      opens: @start_lead_blocks,
      length: @auction_duration_blocks,
      claim: @claim_delay_blocks,
      pool: @migration_delay_blocks
    }

  def floor_price_q96, do: @floor_price_q96

  @doc """
  The stock a launch must raise to graduate: the whole sale at the floor,
  rounded up, as `StocksPreset.REQUIRED_STOCK_RAISED` derives it.
  """
  def required_stock_raised,
    do: div(@auction_inventory * @floor_price_q96 + @q96 - 1, @q96)

  @doc """
  The minimum the site shows: the required raise plus one base unit, because
  the auction may count a bid placed after its first block one unit short.
  """
  def minimum_raise, do: required_stock_raised() + 1

  @doc """
  Reviews one saved draft for `address`, one of the account's own wallets: one
  snapshot, one saved review. The result carries the review's chain, its one
  step and the facts the page shows.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(draft_id, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         :ok <- LaunchOperations.signer_matches(account, signer),
         {:ok, draft} <- owned_draft(draft_id, actor),
         {:ok, fields} <- launchable(draft),
         {:ok, config} <- stocks_lab(),
         {:ok, snapshot} <- snapshot(fields),
         {:ok, executable} <- executable(fields, snapshot, config),
         review <- review(draft, fields, executable, signer, snapshot, config),
         {:ok, operation} <- open(lease, draft, signer, review) do
      {:ok, reviewed(operation)}
    end
  end

  @doc """
  Whether the review on the page still stands on Base as it is now: launches
  open, and the STOCK admitted on the launchpad it was built against with the
  same decimals and route. `:changed` means the page builds it again;
  `:unread` means Base could not be read, and the review stays as it is.
  """
  @spec current(map()) :: :current | :changed | :unread
  def current(%{facts: facts}) do
    case snapshot(%{stock: facts["stock"]}) do
      {:ok, snapshot} -> if standing?(snapshot, facts), do: :current, else: :changed
      {:error, _unread} -> :unread
    end
  end

  defp standing?(%{paused: paused, admission: admission} = snapshot, facts),
    do:
      not paused and admission.admitted and snapshot.launchpad == facts["launchpad"] and
        Integer.to_string(admission.decimals) == facts["stock_decimals"] and
        admission.route == facts["route"]

  @doc "Withdraws one saved review the page is done with."
  def cancel(action_id, opts) do
    with {:ok, _actor} <- human(opts),
         {:ok, lease} <- lease(opts),
         do: transact(lease, &withdraw(&1, action_id))
  end

  defp withdraw(account, action_id) do
    with {:ok, operation} <- LaunchOperations.fetch(account.id, action_id, true),
         do: LaunchOperations.update(operation, :cancel, %{reason: @withdrawn})
  end

  @doc "A saved review as the page uses it: its id, signer, chain, step and facts."
  def reviewed(%{action_id: action_id, review: review}) do
    %{"chain" => chain, "signer" => signer, "step" => step, "facts" => facts} = review

    %{
      action_id: action_id,
      signer: signer,
      chain: %{chain_id: chain["chain_id"], name: chain["name"], rpc_url: chain["rpc_url"]},
      steps: [Review.step(step["step"], step["to"], step["data"])],
      facts: facts
    }
  end

  # Executable values

  @doc """
  Everything the chain will execute, from the preset and the admitted STOCK's
  decimals. Exposed so the review page and its test can state exactly the
  same numbers.
  """
  def executable(_fields, snapshot, _config) do
    with :ok <- admitted(snapshot) do
      {:ok,
       %{
         floor_price_q96: @floor_price_q96,
         tick_spacing_q96: div(@floor_price_q96, @tick_divisor),
         required_stock_raised: required_stock_raised(),
         stock_decimals: snapshot.admission.decimals
       }}
    end
  end

  defp admitted(%{paused: true}), do: unavailable(:launches_paused)
  defp admitted(%{admission: %{admitted: false}}), do: unavailable(:stock_not_admitted)
  defp admitted(_snapshot), do: :ok

  # Reviews

  # The saved review: fixed once written, and read back exactly as stored.
  defp review(draft, fields, executable, signer, snapshot, config) do
    %{
      "chain" => Client.chain(config),
      "signer" => signer,
      "step" => Review.step("launch", snapshot.launchpad, launch_data(fields, config)),
      "facts" => %{
        "draft_id" => draft.id,
        "name" => fields.name,
        "symbol" => fields.symbol,
        "description" => fields.description,
        "website" => fields.website,
        "telegram" => fields.telegram,
        "discord" => fields.discord,
        "links" => fields.links,
        "image" => fields.image,
        "stock" => fields.stock,
        "stock_symbol" => fields.stock_symbol,
        "stock_decimals" => Integer.to_string(executable.stock_decimals),
        "start_lead_blocks" => Integer.to_string(@start_lead_blocks),
        "auction_duration_blocks" => Integer.to_string(@auction_duration_blocks),
        "required_stock_raised" => Integer.to_string(executable.required_stock_raised),
        "minimum_raise_units" => Rpc.format_units(minimum_raise(), executable.stock_decimals),
        "floor_price_q96" => Integer.to_string(executable.floor_price_q96),
        "floor_price_executable" =>
          Amounts.format_cca_price(
            executable.floor_price_q96,
            executable.stock_decimals,
            @new_decimals
          ),
        "tick_spacing_q96" => Integer.to_string(executable.tick_spacing_q96),
        "launchpad" => snapshot.launchpad,
        "hook" => snapshot.hook,
        "route" => snapshot.admission.route,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "terms" => Enum.map(terms(fields.symbol), fn {label, value} -> [label, value] end),
        "risk" => risk_copy()
      }
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @doc "The exact `launch(LaunchParams)` calldata for reviewed fields and executable values."
  def launch_data(fields, config) do
    LabAbi.encode(Lab.abi!(config, :launchpad), StocksLabAbi.launch_signature(), [
      [
        fields.name,
        fields.symbol,
        fields.description,
        fields.website,
        fields.image,
        fields.stock
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
         {:ok, stock} <- address(asset.address, :stock_invalid) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: LaunchDraft.onchain_website(draft),
         telegram: draft.telegram,
         discord: draft.discord,
         links: LaunchLinks.others(draft),
         image: draft.image,
         stock: stock,
         stock_symbol: asset.symbol
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

  # Saved reviews

  defp open(lease, draft, signer, review) do
    transact(lease, fn account ->
      with :ok <- LaunchOperations.signer_matches(account, signer) do
        LaunchOperations.create(account, %{
          action_id: action_id(),
          launch_draft_id: draft.id,
          review: review,
          signer: signer,
          step: :launch
        })
      end
    end)
  end

  defp action_id, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp transact(lease, callback), do: LaunchOperations.transact(lease, callback)

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

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
