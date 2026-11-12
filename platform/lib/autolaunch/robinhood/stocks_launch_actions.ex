defmodule Autolaunch.Robinhood.StocksLaunchActions do
  @moduledoc """
  The one boundary between a creator's wallet and the Robinhood Stocks launchpad.

  Preparation reads the Robinhood chain once and returns the review's chain,
  its one `launch(LaunchParams)` step and the facts the page shows; the page
  keeps it. What it would launch is recorded (`Autolaunch.Robinhood.LaunchReview`)
  so Robinhood discovery can tell this site's launches from launches seen only on
  chain. `confirmed/2` reads the receipt through
  `Autolaunch.Robinhood.StocksLaunchChainClient`, and a wallet's launches are the
  launchpad's own `StockLaunchCreated` records for that wallet.

  Every call binds to one of the wallets of the account the session lease
  names, read inside the lease at call time.

  Every launch opens at the lowest price the auction accepts, and its minimum
  raise is the whole sale at that price, the same rule as on Base
  (`Autolaunch.Stocks.LaunchActions`). The creator chooses neither. Bidding
  opens a fixed number of blocks after the block the launch is created in, so
  the receipt is the only source of the start and end blocks.
  """

  import Autolaunch.Stocks.LaunchOperations, only: [chain: 1, unavailable: 1]

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, Lifecycle, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{Lab, StocksLaunchChainClient}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi

  alias Autolaunch.Stocks.{Amounts, LaunchActions, LaunchOperations}
  alias RegentChain.{Address, Review}

  @new_decimals 18

  @doc """
  Reviews one saved Robinhood draft for `address`, one of the account's own
  wallets: one snapshot, then the review's signer, chain and one step, the
  facts it was built from and the plain facts the page shows.
  """
  @spec prepare(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(draft_id, address, opts) do
    with {:ok, %{actor: actor, signer: signer}} <-
           LaunchOperations.signed_in_wallet(address, opts),
         {:ok, draft} <- owned_draft(draft_id, actor),
         {:ok, fields} <- LaunchActions.launchable(draft),
         {:ok, config} <- robinhood_lab(),
         {:ok, snapshot} <- snapshot(fields.stock),
         {:ok, executable} <- LaunchActions.executable(snapshot),
         {:ok, _review} <- record_review(actor, signer, fields),
         do: {:ok, build(draft, fields, executable, signer, snapshot, config)}
  end

  @doc """
  Whether the review on the page still stands on Robinhood Chain as it is now:
  launches open, and the STOCK admitted on the launchpad it was built against
  with the same decimals and route. `:changed` means the page builds it again;
  `:unread` means the chain could not be read, and the review stays as it is.
  """
  @spec current(map()) :: :current | :changed | :unread
  def current(%{facts: facts}) do
    case snapshot(facts["stock"]) do
      {:ok, snapshot} -> if LaunchActions.standing?(snapshot, facts), do: :current, else: :changed
      {:error, _unread} -> :unread
    end
  end

  # The launch this review would carry out, kept so Robinhood discovery knows it
  # as this site's launch whether or not the browser reports it back.
  defp record_review(%Human{human_account_id: account_id}, signer, fields),
    do:
      Autolaunch.record_robinhood_launch_review(
        %{
          chain_id: Lab.chain_id(),
          signer: signer,
          human_account_id: account_id,
          name: fields.name,
          symbol: fields.symbol,
          stock: fields.stock,
          telegram: fields.telegram,
          discord: fields.discord,
          links: fields.links
        },
        actor: %Autolaunch.Actors.System{}
      )

  @doc """
  Reads the launch `hash` sent from a prepared review back from the chain: `:pending`,
  `:reverted`, `:unverified`, or `:confirmed` with the launchpad's record of
  the launch.
  """
  @spec confirmed(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def confirmed(%{signer: signer, steps: [step], facts: facts}, hash),
    do: chain(StocksLaunchChainClient.verify(signer, step, facts, hash))

  @doc """
  Every launch the launchpad records for `address`, one of the account's own
  wallets, read at one pinned block: the `StockLaunchCreated` logs for that
  launcher from the chain's first block to the pinned block, each confirmed
  against `launches(launchId)` at the same block. A malformed log or a record that does not name the wallet
  refuses the whole read rather than dropping an entry.
  """
  @spec launches(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def launches(address, opts) do
    with {:ok, %{signer: signer}} <- LaunchOperations.signed_in_wallet(address, opts),
         {:ok, config} <- robinhood_lab(),
         rpc <- Lab.rpc_opts(config),
         {:ok, block} <- chain(Rpc.latest_block(rpc)),
         {:ok, logs} <- launch_logs(signer, block, config, rpc),
         {:ok, launches} <- launch_records(logs, signer, block, config, rpc) do
      {:ok, %{block: block, launches: launches}}
    end
  end

  # The review

  defp build(draft, fields, executable, signer, snapshot, config) do
    schedule = LaunchActions.schedule(:robinhood)

    %{
      signer: signer,
      chain: Client.chain(config),
      steps: [
        Review.step("launch", snapshot.launchpad, launch_data(fields, config))
      ],
      facts: %{
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
        "agent_set_fields" => Enum.map(draft.agent_set_fields, &Atom.to_string/1),
        "stock_decimals" => Integer.to_string(executable.stock_decimals),
        "start_lead_blocks" => Integer.to_string(schedule.opens),
        "auction_duration_blocks" => Integer.to_string(schedule.length),
        "required_stock_raised" => Integer.to_string(executable.required_stock_raised),
        "floor_price_q96" => Integer.to_string(executable.floor_price_q96),
        "tick_spacing_q96" => Integer.to_string(executable.tick_spacing_q96),
        "launchpad" => snapshot.launchpad,
        "route" => snapshot.admission.route,
        "block_number" => snapshot.block.number,
        "block_hash" => snapshot.block.hash,
        "terms" =>
          Enum.map(LaunchActions.terms(:robinhood, fields.symbol), fn {label, value} ->
            [label, value]
          end),
        "risk" => risk_copy()
      },
      review: review(fields, executable, schedule)
    }
  end

  # The plain facts the page shows before anything is signed.
  defp review(fields, executable, schedule) do
    [
      ["Launch fee", "None"],
      [
        "Minimum raise",
        "#{RegentFormat.token_amount(LaunchActions.minimum_raise(), executable.stock_decimals)} #{fields.stock_symbol}"
      ],
      [
        "Bidding opens",
        "#{LaunchActions.schedule_copy(:robinhood, schedule.opens)} after the launch is created"
      ],
      ["Auction length", LaunchActions.schedule_copy(:robinhood, schedule.length)],
      ["Starting price", starting_price(fields, executable)]
    ]
  end

  # The page shows a readable price; the review's facts keep the exact one.
  defp starting_price(fields, executable) do
    price =
      executable.floor_price_q96
      |> Amounts.format_cca_price(executable.stock_decimals, @new_decimals)
      |> Decimal.new(max_digits: :infinity)

    "#{RegentFormat.amount(price)} #{fields.stock_symbol} per token, the lowest the auction accepts"
  end

  defp launch_data(fields, config) do
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
            fields.image
          ],
          fields.stock
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
           shape = RobinhoodLabAbi.shape(:v2),
           {:ok, words} <-
             Rpc.call_words(
               launchpad,
               LabAbi.encode(abi, "launches(uint256)", [created.launch_id]),
               block,
               shape.record_words,
               rpc
             ),
           {:ok, launch} <- launch_record(created, RobinhoodLabAbi.record(shape, words)) do
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
  # the launcher is the wallet asked about.
  defp launch_created(abi, log, launchpad, signer) do
    with {:ok,
          {[launch_id, launcher_word, new_token_word],
           [
             stock_word,
             auction_word,
             start_block,
             end_block,
             _auction_inventory,
             _migration_reserve,
             _creator_vesting
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
         end_block: end_block
       }}
    else
      _ -> :error
    end
  end

  # Every fact the event announced must be repeated by the launchpad's record;
  # only the later blocks and the lifecycle are new.
  defp launch_record(created, record) do
    with {:ok, launcher} <- Abi.word_address(record.launcher),
         {:ok, new_token} <- Abi.word_address(record.new_token),
         {:ok, stock} <- Abi.word_address(record.currency),
         {:ok, auction} <- Abi.word_address(record.auction),
         true <-
           Address.equal?(launcher, created.launcher) and
             Address.equal?(new_token, created.new_token) and
             Address.equal?(stock, created.stock) and
             Address.equal?(auction, created.auction) and
             record.start_block == created.start_block and
             record.end_block == created.end_block,
         {:ok, lifecycle} <- Lifecycle.fetch(record.lifecycle) do
      {:ok,
       %{
         "launch_id" => Integer.to_string(created.launch_id),
         "launcher" => launcher,
         "new_token" => new_token,
         "stock" => stock,
         "auction" => auction,
         "start_block" => Integer.to_string(record.start_block),
         "end_block" => Integer.to_string(record.end_block),
         "claim_block" => Integer.to_string(record.claim_block),
         "migration_block" => Integer.to_string(record.migration_block),
         "lifecycle" => Atom.to_string(lifecycle)
       }}
    else
      _ -> :error
    end
  end

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

  # Stored drafts

  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_stocks_launch_draft_by_id(draft_id, actor: actor) do
      {:ok, %{chain: :robinhood} = draft} -> {:ok, draft}
      {:ok, _other} -> unavailable(:launch_draft_not_found)
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end
end
