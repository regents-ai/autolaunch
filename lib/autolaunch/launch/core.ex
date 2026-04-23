defmodule Autolaunch.Launch.Core do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Contract, as: CCAContract
  alias Autolaunch.CCA.Market, as: CCAMarket
  alias Autolaunch.ERC8004
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.AuctionDetails
  alias Autolaunch.Launch.Bid
  alias Autolaunch.Launch.BidFlow
  alias Autolaunch.Launch.Deployment
  alias Autolaunch.Launch.Directory
  alias Autolaunch.Launch.External.TokenLaunch
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo
  alias Autolaunch.Siwa
  alias Autolaunch.TokenPricing
  alias Autolaunch.Trust

  @agent_launch_total_supply "100000000000000000000000000000"
  @eligibility_check_keys ~w(ownerOrOperatorAuthorized noPriorSuccessfulLaunch)
  @fee_split %{
    headline: "2% pool fee -> 1% subject treasury lane + 1% Regent/protocol lane.",
    trade_fee_bps: 200,
    agent_revenue_bps: 100,
    protocol_bps: 100
  }
  @directory_supply Decimal.new("100000000000")
  @chain_configs %{
    84_532 => %{
      id: 84_532,
      key: "base-sepolia",
      family: "base",
      label: "Base Sepolia",
      short_label: "Base Sepolia",
      uniswap_network: "base_sepolia",
      testnet?: true
    },
    8_453 => %{
      id: 8_453,
      key: "base-mainnet",
      family: "base",
      label: "Base",
      short_label: "Base",
      uniswap_network: "base",
      testnet?: false
    }
  }
  @supported_chain_ids [84_532, 8_453]

  def fee_split_summary, do: @fee_split

  def record_world_agentbook_completion(launch_job_id, attrs)
      when is_binary(launch_job_id) and is_map(attrs) do
    human_id = normalize_optional_text(Map.get(attrs, :human_id), 255)
    network = normalize_optional_text(Map.get(attrs, :network), 32) || "world"

    if is_binary(human_id) and human_id != "" do
      if job = Repo.get(Job, launch_job_id) do
        _ =
          job
          |> Job.update_changeset(%{
            world_registered: true,
            world_human_id: human_id,
            world_network: network
          })
          |> Repo.update()
      end

      if auction = Repo.get_by(Auction, source_job_id: launch_job_auction_id(launch_job_id)) do
        _ =
          auction
          |> Auction.changeset(%{
            world_registered: true,
            world_human_id: human_id,
            world_network: network
          })
          |> Repo.update()
      end

      {:ok, %{job_id: launch_job_id, human_id: human_id, network: network}}
    else
      {:error, :invalid_human_id}
    end
  rescue
    _ -> {:error, :record_update_failed}
  end

  def chain_options do
    Enum.map(@supported_chain_ids, fn chain_id ->
      config = chain_config!(chain_id)

      %{
        id: config.id,
        key: config.key,
        family: config.family,
        label: config.label,
        short_label: config.short_label,
        testnet?: config.testnet?
      }
    end)
  end

  def list_agents(nil), do: []

  def list_agents(%HumanUser{} = human) do
    wallet_addresses = linked_wallet_addresses(human)

    if wallet_addresses == [] do
      []
    else
      wallet_addresses
      |> ERC8004.list_accessible_identities(@supported_chain_ids)
      |> Enum.map(&agent_card_from_identity(&1, wallet_addresses))
    end
  rescue
    Req.TransportError -> []
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
    Ecto.QueryError -> []
  end

  def get_agent(%HumanUser{} = human, agent_id) when is_binary(agent_id) do
    Enum.find(list_agents(human), &(&1.agent_id == agent_id or &1.id == agent_id))
  end

  def get_agent(_human, _agent_id), do: nil

  def controls_agent?(%HumanUser{} = human, agent_id) when is_binary(agent_id) do
    not is_nil(get_agent(human, agent_id))
  end

  def controls_agent?(_human, _agent_id), do: false

  def launch_readiness_for_agent(nil, _agent_id), do: nil

  def launch_readiness_for_agent(%HumanUser{} = human, agent_id) do
    if blank?(agent_id), do: nil, else: human |> get_agent(agent_id) |> agent_readiness()
  rescue
    Req.TransportError -> nil
    DBConnection.ConnectionError -> nil
    Postgrex.Error -> nil
    Ecto.QueryError -> nil
  end

  def preview_launch(attrs, %HumanUser{} = human) do
    with :ok <- ensure_authenticated_human(human),
         agent when is_map(agent) <- get_agent(human, Map.get(attrs, :agent_id)),
         :ok <- ensure_agent_eligible(agent),
         {:ok, token_name} <-
           required_text(Map.get(attrs, :token_name), 80, :token_name_required),
         {:ok, token_symbol} <-
           required_text(Map.get(attrs, :token_symbol), 16, :token_symbol_required),
         {:ok, minimum_raise_decimal} <-
           required_decimal(Map.get(attrs, :minimum_raise_usdc), :minimum_raise_required),
         :ok <- ensure_positive_decimal(minimum_raise_decimal, :minimum_raise_required),
         {:ok, minimum_raise_raw} <- decimal_to_wei(minimum_raise_decimal),
         {:ok, agent_safe_address} <-
           required_address(Map.get(attrs, :agent_safe_address)),
         {:ok, chain} <- normalize_launch_chain() do
      total_supply = normalize_total_supply(Map.get(attrs, :total_supply))
      launch_notes = normalize_optional_text(Map.get(attrs, :launch_notes), 1_000)
      trust = trust_summary(agent.agent_id, agent, %{ens_name: agent.ens})

      preview = %{
        agent: agent,
        token: %{
          name: token_name,
          symbol: token_symbol,
          minimum_raise_usdc: decimal_string(minimum_raise_decimal, 6),
          minimum_raise_usdc_raw: Integer.to_string(minimum_raise_raw),
          chain: chain.key,
          chain_id: chain.id,
          chain_family: chain.family,
          chain_label: chain.label,
          agent_safe_address: agent_safe_address,
          total_supply: total_supply
        },
        economics: fee_split_summary(),
        launch_ready: true,
        launch_blockers: [],
        permanence_notes: [
          "One ERC-8004 identity can launch at most one Agent Coin.",
          "AgentLaunchToken supply is fixed at 100 billion from launch.",
          "The Agent Safe is locked into the launch configuration you sign.",
          "Only Base USDC that reaches the revsplit counts as recognized subject revenue."
        ],
        next_steps: [
          "Sign the SIWA message with a linked wallet that controls this ERC-8004 identity.",
          "Queue the Base-family launch deployment.",
          "Wait for the deploy script to return the strategy, vesting wallet, fee hook, subject registry, revenue splitter, and ingress addresses.",
          "Wait for the auction page, then stake claimed tokens to earn recognized Base USDC revenue."
        ],
        launch_notes: launch_notes,
        completion_plan:
          completion_plan(trust, %{
            agent_id: agent.agent_id,
            token_address: nil,
            launch_job_id: nil
          }),
        reputation_prompt:
          reputation_prompt(trust, %{
            agent_id: agent.agent_id,
            token_address: nil,
            launch_job_id: nil
          })
      }

      {:ok, preview}
    else
      nil -> {:error, :agent_not_found}
      {:error, _} = error -> error
      %{} = agent -> {:error, {:agent_not_eligible, agent}}
    end
  end

  def preview_launch(_attrs, _human), do: {:error, :unauthorized}

  def create_launch_job(attrs, human, request_ip),
    do: create_launch_job(attrs, human, request_ip, [])

  def create_launch_job(attrs, %HumanUser{} = human, request_ip, opts) do
    with :ok <- ensure_authenticated_human(human),
         {:ok, preview} <- preview_launch(attrs, human),
         {:ok, wallet_address} <- required_address(Map.get(attrs, :wallet_address)),
         {:ok, message} <- required_text(Map.get(attrs, :message), 8_000, :message_required),
         {:ok, signature} <-
           required_text(Map.get(attrs, :signature), 4_000, :signature_required),
         {:ok, nonce} <- required_text(Map.get(attrs, :nonce), 255, :nonce_required),
         :ok <- ensure_wallet_matches_human(human, wallet_address),
         {:ok, chain_id} <- launch_chain_id(),
         {:ok, _verification} <-
           Siwa.verify_wallet_signature(%{
             wallet_address: wallet_address,
             chain_id: chain_id,
             nonce: nonce,
             message: message,
             signature: signature
           }) do
      issued_at = parse_issued_at(Map.get(attrs, :issued_at))
      broadcast = truthy?(Map.get(attrs, :broadcast, true))
      job_id = "job_" <> Ecto.UUID.generate()

      agent = preview.agent

      job_attrs = %{
        job_id: job_id,
        privy_user_id: human.privy_user_id,
        owner_address: wallet_address,
        agent_id: agent.agent_id,
        agent_name: agent.name,
        ens_name: agent.ens,
        token_name: preview.token.name,
        token_symbol: preview.token.symbol,
        minimum_raise_usdc: preview.token.minimum_raise_usdc,
        minimum_raise_usdc_raw: preview.token.minimum_raise_usdc_raw,
        agent_safe_address: preview.token.agent_safe_address,
        network: preview.token.chain,
        chain_id: chain_id,
        broadcast: broadcast,
        status: "queued",
        step: "queued",
        launch_notes: preview.launch_notes,
        total_supply: preview.token.total_supply,
        lifecycle_run_id: agent.lifecycle_run_id,
        message: message,
        siwa_nonce: nonce,
        siwa_signature: signature,
        issued_at: issued_at,
        request_ip: request_ip,
        script_target: Deployment.deploy_script_target(),
        deploy_workdir: Deployment.deploy_workdir(),
        deploy_binary: Deployment.deploy_binary(),
        rpc_host: Deployment.deploy_rpc_host(chain_id)
      }

      {:ok, job} =
        %Job{}
        |> Job.create_changeset(job_attrs)
        |> Repo.insert()

      Deployment.record_external_launch(job)

      if Keyword.get(opts, :queue?, true) do
        Autolaunch.Launch.Jobs.queue_processing(job.job_id)
      end

      {:ok, serialize_job(job)}
    else
      {:error, _} = error -> error
    end
  end

  def create_launch_job(_attrs, _human, _request_ip, _opts), do: {:error, :unauthorized}

  def get_job_response(job_id) do
    with {:ok, active_chain_id} <- launch_chain_id() do
      case Repo.get(Job, job_id) do
        nil ->
          {:error, :not_found}

        %Job{chain_id: ^active_chain_id} = job ->
          {:ok, %{job: serialize_job(job), auction: maybe_load_job_auction(job)}}

        %Job{} ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  rescue
    DBConnection.ConnectionError -> {:error, :job_lookup_failed}
    Postgrex.Error -> {:error, :job_lookup_failed}
  end

  def list_auctions(filters \\ %{}, current_human \\ nil) do
    Directory.list_auctions(filters, current_human)
  end

  def list_auction_returns(filters \\ %{}, current_human \\ nil) do
    Directory.list_auction_returns(filters, current_human)
  end

  def get_auction(auction_id, current_human \\ nil) do
    AuctionDetails.get_auction(auction_id, current_human)
  end

  def quote_bid(auction_id, attrs, current_human \\ nil) do
    BidFlow.quote_bid(auction_id, attrs, current_human)
  end

  def place_bid(auction_id, attrs, %HumanUser{} = human) do
    BidFlow.place_bid(auction_id, attrs, human)
  end

  def place_bid(_auction_id, _attrs, _human), do: {:error, :unauthorized}

  def list_positions(human, filters \\ %{})

  def list_positions(nil, _filters), do: []

  def list_positions(%HumanUser{} = human, filters) do
    BidFlow.list_positions(human, filters)
  end

  def exit_bid(bid_id, attrs, %HumanUser{} = human) do
    BidFlow.exit_bid(bid_id, attrs, human)
  end

  def exit_bid(_bid_id, _attrs, _human), do: {:error, :unauthorized}

  def return_bid(bid_id, attrs, current_human), do: exit_bid(bid_id, attrs, current_human)

  def claim_bid(bid_id, attrs, %HumanUser{} = human) do
    BidFlow.claim_bid(bid_id, attrs, human)
  end

  def claim_bid(_bid_id, _attrs, _human), do: {:error, :unauthorized}

  defp agent_card_from_identity(identity, wallet_addresses) do
    existing_launch =
      Repo.one(
        from launch in TokenLaunch,
          where: launch.agent_id == ^identity.agent_id,
          order_by: [desc: launch.inserted_at],
          limit: 1
      )

    active_launch? =
      existing_launch && existing_launch.launch_status in ["queued", "running", "succeeded"]

    state =
      cond do
        active_launch? -> "already_launched"
        identity.access_mode in ["owner", "operator"] -> "eligible"
        true -> "wallet_bound"
      end

    readiness = agent_readiness(identity, existing_launch)
    blockers = launch_blockers(readiness)

    %{
      id: identity.agent_id,
      agent_id: identity.agent_id,
      name: identity.name,
      source: identity.source,
      supported_chains: chain_options(),
      state: state,
      access_mode: identity.access_mode,
      owner_address: identity.owner_address,
      operator_addresses: identity.operator_addresses,
      agent_wallet: identity.agent_wallet,
      image_url: identity.image_url,
      description: identity.description,
      ens: identity.ens,
      agent_uri: identity.agent_uri,
      web_endpoint: identity.web_endpoint,
      registry_address: identity.registry_address,
      token_id: identity.token_id,
      linked_wallet_addresses: wallet_addresses,
      blocker_texts: blockers,
      lifecycle_run_id: identity.agent_id,
      existing_token:
        if(existing_launch,
          do: %{
            status: existing_launch.launch_status,
            auction_id: existing_launch.launch_job_id,
            symbol: Map.get(existing_launch.metadata || %{}, "token_symbol"),
            token_address: existing_launch.token_address,
            auction_address: existing_launch.auction_address
          },
          else: nil
        )
    }
  end

  defp agent_readiness(nil), do: nil

  defp agent_readiness(agent) when is_map(agent) do
    agent_readiness(agent, agent[:existing_token])
  end

  defp agent_readiness(identity, existing_launch) do
    owner_or_operator? = identity.access_mode in ["owner", "operator"]
    existing_launch? = active_launch_record?(existing_launch)

    checks = [
      %{
        key: "ownerOrOperatorAuthorized",
        passed: owner_or_operator?,
        message:
          if(owner_or_operator?,
            do: "This linked wallet controls the ERC-8004 identity as owner or operator.",
            else:
              "This identity is only wallet-bound. Launching requires ERC-8004 owner or operator access."
          )
      },
      %{
        key: "noPriorSuccessfulLaunch",
        passed: not existing_launch?,
        message:
          if(existing_launch?,
            do: "This ERC-8004 identity already has an Agent Coin launch recorded.",
            else: "No prior Agent Coin launch is attached to this ERC-8004 identity."
          )
      }
    ]

    %{
      ready_to_launch: Enum.all?(checks, & &1.passed),
      resolved_lifecycle_run_id: identity.agent_id,
      stake_lock_id: nil,
      blocking_status_code: if(Enum.all?(checks, & &1.passed), do: "ready", else: "blocked"),
      blocking_status_message:
        if(Enum.all?(checks, & &1.passed),
          do: "ERC-8004 identity is ready for launch.",
          else: "Resolve the highlighted launch blocker before continuing."
        ),
      checks: checks
    }
  end

  defp launch_blockers(%{checks: checks}) do
    checks
    |> Enum.filter(fn check -> check.key in @eligibility_check_keys and not check.passed end)
    |> Enum.map(& &1.message)
  end

  defp active_launch_record?(%{launch_status: status}),
    do: status in ["queued", "running", "succeeded"]

  defp active_launch_record?(%{status: status}), do: status in ["queued", "running", "succeeded"]
  defp active_launch_record?(_record), do: false

  defp ensure_agent_eligible(%{state: "eligible"}), do: :ok
  defp ensure_agent_eligible(agent), do: {:error, {:agent_not_eligible, agent}}

  def serialize_tx_request(%{chain_id: chain_id, to: to, value_hex: value_hex, data: data}) do
    %{
      chain_id: chain_id,
      to: to,
      value: value_hex,
      data: data
    }
  end

  def serialize_action_request(nil), do: nil

  def serialize_action_request(%{tx_request: tx_request} = action) do
    action
    |> Map.drop([:tx_request])
    |> Map.put(:tx_request, serialize_tx_request(tx_request))
  end

  defp derive_position_status(%Bid{claimed_at: %DateTime{}}, _auction), do: "claimed"
  defp derive_position_status(%Bid{exited_at: %DateTime{}}, _auction), do: "exited"

  defp derive_position_status(%Bid{} = bid, auction) do
    clearing =
      parse_decimal(
        auction[:current_clearing_price] || decimal_string(bid.current_clearing_price)
      )

    compare = Decimal.compare(bid.max_price, clearing)

    cond do
      compare == :lt ->
        "inactive"

      Decimal.compare(bid.max_price, Decimal.mult(clearing, decimal("1.03"))) == :lt ->
        "borderline"

      true ->
        "active"
    end
  end

  def serialize_auction(
        %Auction{} = auction,
        current_human,
        identity_index,
        job_index,
        human_launch_counts,
        x_accounts
      ) do
    public_id = auction.source_job_id || "auc_#{auction.id}"
    your_bid_status = current_bid_status(public_id, current_human)
    chain = chain_config(auction.chain_id)
    live_snapshot = load_live_snapshot(auction)
    clearing_q96 = live_snapshot[:clearing_price_q96]
    currency_raised_wei = live_snapshot[:currency_raised_wei]
    job = Map.get(job_index, source_job_to_job_id(auction.source_job_id))
    identity = Map.get(identity_index, auction.agent_id)
    ens_name = live_ens_name(identity, auction)
    world_human_id = auction.world_human_id

    world_registered =
      truthy?(auction.world_registered) and is_binary(world_human_id) and world_human_id != ""

    trust =
      trust_summary(auction.agent_id, identity, %{
        ens_name: ens_name,
        world_connected: world_registered,
        world_human_id: world_human_id,
        world_network: auction.world_network || "world",
        world_launch_count: Map.get(human_launch_counts, world_human_id, 0),
        x_account: Map.get(x_accounts, auction.agent_id)
      })

    total_bid_volume =
      if(is_integer(currency_raised_wei),
        do: wei_to_float(currency_raised_wei),
        else: parse_float(auction.raised_currency)
      )

    current_clearing_price =
      if(is_integer(clearing_q96),
        do: q96_price_to_string(clearing_q96),
        else: decimal_string(derived_clearing_price(auction))
      )

    required_currency_raised_raw =
      cond do
        is_integer(live_snapshot[:required_currency_raised_wei]) ->
          Integer.to_string(live_snapshot[:required_currency_raised_wei])

        is_binary(auction.minimum_raise_usdc_raw) and auction.minimum_raise_usdc_raw != "" ->
          auction.minimum_raise_usdc_raw

        job && is_binary(job.minimum_raise_usdc_raw) && job.minimum_raise_usdc_raw != "" ->
          job.minimum_raise_usdc_raw

        true ->
          nil
      end

    required_currency_raised =
      cond do
        is_integer(live_snapshot[:required_currency_raised_wei]) ->
          wei_to_string(live_snapshot[:required_currency_raised_wei])

        is_binary(auction.minimum_raise_usdc) and auction.minimum_raise_usdc != "" ->
          auction.minimum_raise_usdc

        job && is_binary(job.minimum_raise_usdc) && job.minimum_raise_usdc != "" ->
          job.minimum_raise_usdc

        true ->
          nil
      end

    minimum_raise_progress_percent =
      minimum_raise_progress_percent(currency_raised_wei, required_currency_raised_raw)

    minimum_raise_met =
      minimum_raise_met?(currency_raised_wei, required_currency_raised_raw, live_snapshot)

    projected_final_currency_raised_raw =
      projected_final_currency_raised_raw(
        currency_raised_wei,
        auction.started_at,
        auction.ends_at
      )

    projected_final_currency_raised =
      if is_binary(projected_final_currency_raised_raw),
        do: wei_to_string(String.to_integer(projected_final_currency_raised_raw)),
        else: nil

    time_remaining_seconds = time_remaining_seconds(auction.ends_at)
    auction_outcome = auction_outcome(auction, live_snapshot, minimum_raise_met)

    phase = auction_phase(auction, live_snapshot)

    {current_price_usdc, price_source} =
      current_directory_price(
        phase,
        auction,
        job,
        current_clearing_price
      )

    implied_market_cap_usdc = implied_market_cap(current_price_usdc)
    detail_url = "/auctions/#{public_id}"

    subject_url =
      if job && is_binary(job.subject_id) && job.subject_id != "" do
        "/subjects/#{job.subject_id}"
      else
        nil
      end

    %{
      id: public_id,
      agent_id: auction.agent_id,
      agent_name: auction.agent_name,
      symbol: auction_symbol(auction, public_id),
      owner_address: auction.owner_address,
      auction_address: auction.auction_address,
      token_address: auction.token_address,
      network: auction.network,
      chain: if(chain, do: chain.label, else: auction.network),
      chain_family: if(chain, do: chain.family, else: "unknown"),
      chain_id: auction.chain_id,
      status: auction.status,
      phase: phase,
      started_at: iso(auction.started_at),
      ends_at: iso(auction.ends_at),
      claim_at: iso(auction.claim_at),
      created_at: iso(auction.inserted_at),
      bidders: auction.bidders,
      raised_currency: auction.raised_currency,
      target_currency: auction.target_currency,
      progress_percent: auction.progress_percent,
      required_currency_raised_raw: required_currency_raised_raw,
      required_currency_raised: required_currency_raised,
      currency_raised_raw:
        if(is_integer(currency_raised_wei), do: Integer.to_string(currency_raised_wei), else: nil),
      currency_raised:
        if(is_integer(currency_raised_wei), do: wei_to_string(currency_raised_wei), else: nil),
      minimum_raise_progress_percent: minimum_raise_progress_percent,
      minimum_raise_met: minimum_raise_met,
      is_graduated: truthy?(live_snapshot[:is_graduated]),
      projected_final_currency_raised_raw: projected_final_currency_raised_raw,
      projected_final_currency_raised: projected_final_currency_raised,
      projection_basis: if(projected_final_currency_raised_raw, do: "simple_pace", else: nil),
      auction_outcome: auction_outcome,
      time_remaining_seconds: time_remaining_seconds,
      returns_enabled: auction_outcome == "failed_minimum",
      metrics_updated_at: iso(auction.metrics_updated_at),
      metrics_source:
        if(live_snapshot != %{},
          do: "onchain",
          else: if(auction.metrics_updated_at, do: "live", else: "estimated")
        ),
      quote_mode: if(live_snapshot != %{}, do: "onchain_exact_v1", else: "approximate_preview"),
      current_clearing_price: current_clearing_price,
      current_price_usdc: current_price_usdc,
      price_source: price_source,
      implied_market_cap_usdc: implied_market_cap_usdc,
      total_bid_volume:
        if(is_integer(currency_raised_wei),
          do: wei_to_string(currency_raised_wei),
          else: decimal_string(decimal(total_bid_volume))
        ),
      notes: auction.notes,
      uniswap_url: auction.uniswap_url,
      pool_id: job && job.pool_id,
      subject_id: job && job.subject_id,
      splitter_address: job && job.revenue_share_splitter_address,
      detail_url: detail_url,
      subject_url: subject_url,
      trust: trust,
      completion_plan:
        completion_plan(trust, %{
          agent_id: auction.agent_id,
          token_address: auction.token_address,
          launch_job_id: source_job_to_job_id(auction.source_job_id)
        }),
      reputation_prompt:
        reputation_prompt(trust, %{
          agent_id: auction.agent_id,
          token_address: auction.token_address,
          launch_job_id: source_job_to_job_id(auction.source_job_id)
        }),
      your_bid_status: your_bid_status
    }
  end

  def get_auction_by_address(network, auction_address, _current_human) do
    Repo.get_by(Auction, network: network, auction_address: auction_address)
    |> case do
      nil ->
        nil

      auction ->
        serialize_auction(
          auction,
          nil,
          identity_index_for_auctions([auction]),
          job_index_for_auctions([auction]),
          world_launch_counts(),
          x_accounts_for_auctions([auction])
        )
    end
  rescue
    _ -> nil
  end

  defp current_bid_status(auction_id, %HumanUser{} = human) do
    wallet_address = normalize_address(human.wallet_address)

    bid =
      Repo.one(
        from bid in Bid,
          where: bid.owner_address == ^wallet_address and bid.auction_id == ^auction_id,
          order_by: [desc: bid.inserted_at],
          limit: 1
      )

    auction =
      Repo.one(
        from auction in Auction,
          where: fragment("coalesce(?, '')", auction.source_job_id) == ^auction_id,
          limit: 1
      )

    case {bid, auction} do
      {nil, _} ->
        "none"

      {%Bid{} = tracked_bid, %Auction{} = tracked_auction} ->
        with {:ok, snapshot} <-
               CCAContract.snapshot(tracked_auction.chain_id, tracked_auction.auction_address),
             {:ok, market_position} <- CCAMarket.sync_bid_position(snapshot, tracked_bid) do
          market_position.current_status
        else
          _ ->
            derive_position_status(tracked_bid, %{
              current_clearing_price: decimal_string(tracked_bid.current_clearing_price)
            })
        end

      {%Bid{} = tracked_bid, _} ->
        derive_position_status(tracked_bid, %{
          current_clearing_price: decimal_string(tracked_bid.current_clearing_price)
        })
    end
  rescue
    _ -> "none"
  end

  defp current_bid_status(_auction_id, _human), do: nil

  def normalize_limit(value, _default) when is_integer(value) and value > 0, do: value

  def normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  def normalize_limit(_value, default), do: default

  def normalize_offset(value, _default) when is_integer(value) and value >= 0, do: value

  def normalize_offset(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  def normalize_offset(_value, default), do: default

  defp auction_symbol(auction, public_id) do
    case auction.notes do
      notes when is_binary(notes) ->
        if String.starts_with?(notes, "$") do
          notes
        else
          derived_auction_symbol(public_id)
        end

      _ ->
        derived_auction_symbol(public_id)
    end
  end

  defp derived_auction_symbol(public_id) do
    suffix =
      public_id
      |> String.split("_")
      |> List.last()
      |> String.upcase()

    "$" <> suffix
  end

  def job_index_for_auctions(auctions) do
    job_ids =
      auctions
      |> Enum.map(&source_job_to_job_id(&1.source_job_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.all(
      from job in Job,
        where: job.job_id in ^job_ids
    )
    |> Map.new(&{&1.job_id, &1})
  rescue
    _ -> %{}
  end

  defp auction_phase(%Auction{} = auction, live_snapshot) do
    cond do
      is_map(live_snapshot) and live_snapshot != %{} ->
        if live_snapshot[:is_graduated] or
             live_snapshot[:block_number] >= live_snapshot[:end_block],
           do: "live",
           else: "biddable"

      is_struct(auction.ends_at, DateTime) ->
        if DateTime.compare(auction.ends_at, DateTime.utc_now()) == :gt,
          do: "biddable",
          else: "live"

      true ->
        "live"
    end
  end

  defp current_directory_price("biddable", _auction, _job, current_clearing_price) do
    {current_clearing_price, "auction_clearing"}
  end

  defp current_directory_price("live", auction, %Job{} = job, _current_clearing_price) do
    case price_module().current_token_price_usdc(
           auction.chain_id,
           job.pool_id,
           auction.token_address
         ) do
      {:ok, price} -> {price, "uniswap_spot"}
      _ -> {nil, "uniswap_spot_unavailable"}
    end
  end

  defp current_directory_price("live", _auction, _job, _current_clearing_price),
    do: {nil, "uniswap_spot_unavailable"}

  defp implied_market_cap(nil), do: nil

  defp implied_market_cap(price) when is_binary(price) do
    price
    |> Decimal.new()
    |> Decimal.mult(@directory_supply)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  def sort_timestamp(nil, created_at), do: sort_timestamp(created_at, nil)
  def sort_timestamp(value, _created_at) when is_binary(value), do: value
  def sort_timestamp(%DateTime{} = value, _created_at), do: DateTime.to_unix(value, :microsecond)
  def sort_timestamp(_value, nil), do: 0

  def market_cap_sort_key(nil, :desc), do: {1, Decimal.new(0)}
  def market_cap_sort_key(nil, :asc), do: {1, Decimal.new(0)}

  def market_cap_sort_key(value, :desc) do
    {0, Decimal.negate(Decimal.new(value))}
  end

  def market_cap_sort_key(value, :asc) do
    {0, Decimal.new(value)}
  end

  defp price_module do
    :autolaunch
    |> Application.get_env(:launch, [])
    |> Keyword.get(:token_pricing_module, TokenPricing)
  end

  defp derived_clearing_price(%Auction{} = auction) do
    base = decimal("0.0061")
    multiplier = decimal(Float.to_string(1 + min(auction.progress_percent, 100) / 250))
    Decimal.round(Decimal.mult(base, multiplier), 6)
  end

  def time_remaining_seconds(nil), do: 0

  def time_remaining_seconds(%DateTime{} = datetime) do
    max(DateTime.diff(datetime, DateTime.utc_now(), :second), 0)
  end

  def time_remaining_seconds(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _} -> max(DateTime.diff(datetime, DateTime.utc_now(), :second), 0)
      _ -> 0
    end
  end

  defp minimum_raise_progress_percent(currency_raised_wei, required_currency_raised_raw)
       when is_integer(currency_raised_wei) and is_binary(required_currency_raised_raw) do
    case Integer.parse(required_currency_raised_raw) do
      {required, ""} when required > 0 ->
        currency_raised_wei
        |> Decimal.new()
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.div(Decimal.new(required))
        |> Decimal.round(2)
        |> Decimal.to_float()
        |> min(100.0)

      _ ->
        nil
    end
  end

  defp minimum_raise_progress_percent(_currency_raised_wei, _required_currency_raised_raw),
    do: nil

  defp minimum_raise_met?(currency_raised_wei, required_currency_raised_raw, live_snapshot)
       when is_integer(currency_raised_wei) do
    cond do
      truthy?(live_snapshot[:is_graduated]) ->
        true

      is_binary(required_currency_raised_raw) ->
        case Integer.parse(required_currency_raised_raw) do
          {required, ""} when required > 0 -> currency_raised_wei >= required
          _ -> false
        end

      true ->
        false
    end
  end

  defp minimum_raise_met?(_currency_raised_wei, _required_currency_raised_raw, live_snapshot),
    do: truthy?(live_snapshot[:is_graduated])

  defp projected_final_currency_raised_raw(
         currency_raised_wei,
         %DateTime{} = started_at,
         %DateTime{} = ends_at
       )
       when is_integer(currency_raised_wei) do
    now = DateTime.utc_now()
    total_duration = DateTime.diff(ends_at, started_at, :second)
    elapsed = DateTime.diff(now, started_at, :second)

    cond do
      total_duration <= 0 ->
        nil

      elapsed <= 0 ->
        nil

      DateTime.compare(now, ends_at) != :lt ->
        nil

      true ->
        projected =
          currency_raised_wei
          |> Decimal.new()
          |> Decimal.mult(Decimal.new(total_duration))
          |> Decimal.div(Decimal.new(elapsed))
          |> Decimal.round(0)
          |> Decimal.to_integer()
          |> max(currency_raised_wei)

        Integer.to_string(projected)
    end
  end

  defp projected_final_currency_raised_raw(_currency_raised_wei, _started_at, _ends_at), do: nil

  defp auction_outcome(%Auction{} = auction, live_snapshot, minimum_raise_met) do
    ended? =
      case auction.ends_at do
        %DateTime{} = ends_at -> DateTime.compare(ends_at, DateTime.utc_now()) != :gt
        _ -> false
      end

    cond do
      auction.status == "settled" -> "settled"
      truthy?(live_snapshot[:is_graduated]) -> "graduated"
      ended? and minimum_raise_met == false -> "failed_minimum"
      true -> "active"
    end
  end

  def serialize_job(job) do
    chain = chain_config(job.chain_id)

    trust =
      trust_summary(job.agent_id, nil, %{
        ens_name: job.ens_name,
        world_connected: truthy?(job.world_registered),
        world_human_id: job.world_human_id,
        world_network: job.world_network || "world",
        world_launch_count: world_launch_count(job.world_human_id)
      })

    %{
      job_id: job.job_id,
      owner_address: job.owner_address,
      agent_id: job.agent_id,
      agent_name: job.agent_name,
      token_name: job.token_name,
      token_symbol: job.token_symbol,
      minimum_raise_usdc: job.minimum_raise_usdc,
      minimum_raise_usdc_raw: job.minimum_raise_usdc_raw,
      agent_safe_address: job.agent_safe_address,
      network: job.network,
      chain_id: job.chain_id,
      chain_family: if(chain, do: chain.family, else: nil),
      chain_label: if(chain, do: chain.label, else: job.network),
      status: job.status,
      step: job.step,
      error_message: job.error_message,
      broadcast: job.broadcast,
      total_supply: job.total_supply,
      launch_notes: job.launch_notes,
      nonce: job.siwa_nonce,
      issued_at: iso(job.issued_at),
      lifecycle_run_id: job.lifecycle_run_id,
      auction_address: job.auction_address,
      token_address: job.token_address,
      strategy_address: job.strategy_address,
      vesting_wallet_address: job.vesting_wallet_address,
      hook_address: job.hook_address,
      launch_fee_registry_address: job.launch_fee_registry_address,
      launch_fee_vault_address: job.launch_fee_vault_address,
      subject_registry_address: job.subject_registry_address,
      subject_id: job.subject_id,
      revenue_share_splitter_address: job.revenue_share_splitter_address,
      default_ingress_address: job.default_ingress_address,
      pool_id: job.pool_id,
      tx_hash: job.tx_hash,
      uniswap_url: job.uniswap_url,
      trust: trust,
      started_at: iso(job.started_at),
      finished_at: iso(job.finished_at),
      created_at: iso(job.inserted_at),
      updated_at: iso(job.updated_at),
      completion_plan:
        completion_plan(trust, %{
          agent_id: job.agent_id,
          token_address: job.token_address,
          launch_job_id: job.job_id
        }),
      reputation_prompt:
        reputation_prompt(trust, %{
          agent_id: job.agent_id,
          token_address: job.token_address,
          launch_job_id: job.job_id
        }),
      command_summary: %{
        binary: job.deploy_binary,
        script_target: job.script_target,
        cwd: job.deploy_workdir,
        broadcast: job.broadcast,
        rpc_host: job.rpc_host
      },
      logs: %{
        stdout_tail: job.stdout_tail || "",
        stderr_tail: job.stderr_tail || ""
      }
    }
  end

  def identity_index_for_auctions(auctions) do
    auctions
    |> Enum.map(& &1.agent_id)
    |> Enum.reject(&blank?/1)
    |> ERC8004.get_identities_by_agent_ids()
  end

  def x_accounts_for_auctions(auctions) do
    auctions
    |> Enum.map(& &1.agent_id)
    |> Trust.x_accounts_by_agent_ids()
  end

  defp trust_summary(agent_id, identity, attrs) do
    world_human_id = Map.get(attrs, :world_human_id)

    world_connected =
      truthy?(Map.get(attrs, :world_connected)) and is_binary(world_human_id) and
        world_human_id != ""

    Trust.compose_summary(agent_id, identity, %{
      ens_name: Map.get(attrs, :ens_name),
      world_connected: world_connected,
      world_human_id: world_human_id,
      world_network: Map.get(attrs, :world_network) || "world",
      world_launch_count:
        if(world_connected, do: Map.get(attrs, :world_launch_count, 0), else: 0),
      x_account: Map.get(attrs, :x_account)
    })
  end

  defp live_ens_name(%{ens: ens_name}, _auction) when is_binary(ens_name) and ens_name != "",
    do: ens_name

  defp live_ens_name(_identity, %Auction{ens_name: ens_name})
       when is_binary(ens_name) and ens_name != "", do: ens_name

  defp live_ens_name(_identity, _auction), do: nil

  defp completion_plan(trust, attrs) do
    ens_connected = get_in(trust, [:ens, :connected])
    ens_name = get_in(trust, [:ens, :name])
    world_connected = get_in(trust, [:world, :connected])
    world_human_id = get_in(trust, [:world, :human_id])
    world_network = get_in(trust, [:world, :network]) || "world"
    world_launch_count = get_in(trust, [:world, :launch_count]) || 0
    token_address = Map.get(attrs, :token_address)
    launch_job_id = Map.get(attrs, :launch_job_id)

    %{
      ens: %{
        attached: ens_connected,
        ens_name: ens_name,
        action_url: ens_link_path(Map.get(attrs, :agent_id), ens_name),
        note:
          if(ens_connected,
            do: "ENS link already present on the creator identity.",
            else: "Finish the ENS link so the creator identity advertises a public name."
          )
      },
      agentbook: %{
        attached: world_connected,
        human_id: world_human_id,
        network: world_network,
        launch_count: world_launch_count,
        action_url: agentbook_path(launch_job_id, token_address),
        note:
          cond do
            world_connected ->
              "World AgentBook proof is attached."

            is_binary(token_address) and token_address != "" ->
              "A human must finish the World AgentBook proof for this launched token."

            true ->
              "World AgentBook proof becomes available after the token address exists."
          end
      }
    }
  end

  defp reputation_prompt(trust, attrs) do
    plan = completion_plan(trust, attrs)
    ens_attached = get_in(trust, [:ens, :connected])
    world_attached = get_in(trust, [:world, :connected])
    world = get_in(trust, [:world]) || %{}
    world_action_url = get_in(plan, [:agentbook, :action_url])
    world_ready = is_binary(world_action_url) and world_action_url != ""

    %{
      title: "Improve agent token reputation",
      optional: true,
      prompt:
        "To improve agent token reputation, you can optionally link an ENS name and/or connect to a human's World ID.",
      warning:
        "You can skip this, though the token launch may be less trusted until these links are added.",
      skip_label: "Skip for now",
      instructions: [
        if(ens_attached,
          do: "ENS is already linked for the creator identity.",
          else: "Link an ENS name so the creator identity advertises a public name."
        ),
        cond do
          world_attached ->
            "A human-backed World ID is already attached to this token."

          world_ready ->
            "Ask the human behind this token to complete the World AgentBook proof."

          true ->
            "After launch creates the token address, ask the human behind this token to complete the World AgentBook proof."
        end
      ],
      actions: [
        %{
          key: "ens",
          label: if(ens_attached, do: "Review ENS link", else: "Link ENS name"),
          status: if(ens_attached, do: "complete", else: "available"),
          completed: ens_attached,
          action_url: get_in(plan, [:ens, :action_url]),
          note: get_in(plan, [:ens, :note])
        },
        %{
          key: "world",
          label: if(world_attached, do: "Review World ID", else: "Connect World ID"),
          status:
            cond do
              world_attached -> "complete"
              world_ready -> "available"
              true -> "pending"
            end,
          completed: world_attached,
          action_url: world_action_url,
          note: world_note(get_in(plan, [:agentbook, :note]), world)
        }
      ]
    }
  end

  defp ens_link_path(nil, _ens_name), do: nil

  defp ens_link_path(agent_id, ens_name) do
    query =
      %{"identity_id" => agent_id}
      |> maybe_put_query("ens_name", ens_name)

    "/ens-link?" <> URI.encode_query(query)
  end

  defp agentbook_path(_launch_job_id, token_address) when token_address in [nil, ""], do: nil

  defp agentbook_path(launch_job_id, token_address) do
    query =
      %{"agent_address" => token_address, "network" => "world"}
      |> maybe_put_query("launch_job_id", launch_job_id)

    "/agentbook?" <> URI.encode_query(query)
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp world_note(base_note, %{human_id: human_id, launch_count: launch_count}) do
    cond do
      is_binary(human_id) and human_id != "" and launch_count > 0 ->
        "#{base_note} This human ID has launched #{launch_count} token#{if(launch_count == 1, do: "", else: "s")} through autolaunch."

      is_binary(human_id) and human_id != "" ->
        "#{base_note} Human ID: #{human_id}."

      true ->
        base_note
    end
  end

  defp world_note(base_note, _world), do: base_note

  def world_launch_counts do
    Repo.all(
      from auction in Auction,
        where:
          auction.world_registered == true and not is_nil(auction.world_human_id) and
            auction.world_human_id != "",
        group_by: auction.world_human_id,
        select: {auction.world_human_id, count(auction.id)}
    )
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp world_launch_count(nil), do: 0
  defp world_launch_count(""), do: 0

  defp world_launch_count(human_id) do
    Repo.one(
      from auction in Auction,
        where: auction.world_registered == true and auction.world_human_id == ^human_id,
        select: count(auction.id)
    ) || 0
  rescue
    _ -> 0
  end

  defp launch_job_auction_id("job_" <> rest), do: "auc_" <> rest
  defp launch_job_auction_id(job_id), do: job_id

  defp source_job_to_job_id("auc_" <> rest), do: "job_" <> rest
  defp source_job_to_job_id(_source_job_id), do: nil

  def ensure_authenticated_human(%HumanUser{privy_user_id: privy_user_id})
      when is_binary(privy_user_id), do: :ok

  def ensure_authenticated_human(_human), do: {:error, :unauthorized}

  defp ensure_wallet_matches_human(%HumanUser{} = human, wallet) do
    normalized_wallet = normalize_address(wallet)

    if normalized_wallet in linked_wallet_addresses(human),
      do: :ok,
      else: {:error, :wallet_mismatch}
  end

  defp normalize_launch_chain do
    with {:ok, chain_id} <- launch_chain_id(),
         {:ok, config} <- fetch_chain_config(chain_id) do
      {:ok, config}
    end
  end

  def launch_chain_id do
    normalize_chain_id(Keyword.get(launch_config(), :chain_id, 84_532))
  end

  def iso(nil), do: nil
  def iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp truthy?(value), do: value in [true, "true", "1", 1, "on", "yes"]

  def normalize_address(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: String.downcase(trimmed)
  end

  def normalize_address(_value), do: nil

  def linked_wallet_addresses(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def linked_wallet_addresses(_human), do: []

  def primary_wallet_address(%HumanUser{} = human),
    do: human |> linked_wallet_addresses() |> List.first()

  defp normalize_chain_id(value) when is_integer(value) do
    if value in @supported_chain_ids, do: {:ok, value}, else: {:error, :invalid_chain_id}
  end

  defp normalize_chain_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_chain_id(parsed)
      _ -> {:error, :invalid_chain_id}
    end
  end

  defp normalize_chain_id(_value), do: {:error, :invalid_chain_id}

  defp normalize_total_supply(_value), do: @agent_launch_total_supply

  defp required_text(value, max_length, error_atom) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> {:error, error_atom}
      trimmed -> {:ok, String.slice(trimmed, 0, max_length)}
    end
  end

  defp required_text(_value, _max_length, error_atom), do: {:error, error_atom}

  def required_address(value) do
    case normalize_address(value) do
      address when is_binary(address) ->
        if Regex.match?(~r/^0x[0-9a-f]{40}$/, address) do
          {:ok, address}
        else
          {:error, :invalid_wallet_address}
        end

      _ ->
        {:error, :invalid_wallet_address}
    end
  end

  def required_decimal(value, error_atom) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, error_atom}
    end
  end

  def required_decimal(value, _error_atom) when is_number(value), do: {:ok, decimal(value)}
  def required_decimal(_value, error_atom), do: {:error, error_atom}

  defp ensure_positive_decimal(%Decimal{} = value, error_atom) do
    if Decimal.compare(value, Decimal.new(0)) == :gt, do: :ok, else: {:error, error_atom}
  end

  def required_tx_hash(value) when is_binary(value) do
    tx_hash = String.downcase(String.trim(value))

    if Regex.match?(~r/^0x[0-9a-f]{64}$/, tx_hash) do
      {:ok, tx_hash}
    else
      {:error, :invalid_transaction_hash}
    end
  end

  def required_tx_hash(_value), do: {:error, :invalid_transaction_hash}

  defp normalize_optional_text(value, max_length) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp normalize_optional_text(_value, _max_length), do: nil

  defp parse_issued_at(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp parse_issued_at(_value), do: DateTime.utc_now()

  defp maybe_load_job_auction(%Job{auction_address: address, network: network})
       when is_binary(address) and address != "" do
    get_auction_by_address(network, address, nil)
  end

  defp maybe_load_job_auction(_job), do: nil

  defp blank?(value), do: value in [nil, ""]

  defp launch_config do
    Application.get_env(:autolaunch, :launch, [])
  end

  defp fetch_chain_config(chain_id) do
    case chain_config(chain_id) do
      nil -> {:error, :invalid_chain_id}
      config -> {:ok, config}
    end
  end

  defp chain_config(chain_id), do: Map.get(@chain_configs, chain_id)

  defp chain_config!(chain_id) do
    case chain_config(chain_id) do
      nil -> raise ArgumentError, "unsupported chain id #{inspect(chain_id)}"
      config -> config
    end
  end

  defp load_live_snapshot(%Auction{auction_address: auction_address, chain_id: chain_id})
       when is_binary(auction_address) and is_integer(chain_id) do
    case CCAContract.snapshot(chain_id, auction_address) do
      {:ok, snapshot} ->
        %{
          block_number: snapshot.block_number,
          start_block: snapshot.start_block,
          end_block: snapshot.end_block,
          claim_block: snapshot.claim_block,
          clearing_price_q96: snapshot.checkpoint.clearing_price_q96,
          required_currency_raised_wei: snapshot.required_currency_raised_wei,
          currency_raised_wei: snapshot.currency_raised_wei,
          total_cleared_units: snapshot.total_cleared_units,
          is_graduated: snapshot.is_graduated
        }

      _ ->
        %{}
    end
  end

  defp load_live_snapshot(_auction), do: %{}

  defp parse_float(value) when is_binary(value) do
    value
    |> String.replace("USDC", "")
    |> String.replace("ETH", "")
    |> String.replace(",", "")
    |> String.trim()
    |> Float.parse()
    |> case do
      {parsed, _} -> parsed
      _ -> 0.0
    end
  end

  defp parse_float(value) when is_number(value), do: value * 1.0
  defp parse_float(_value), do: 0.0

  def parse_decimal(value) when is_binary(value), do: decimal(parse_float(value))
  def parse_decimal(%Decimal{} = value), do: value
  def parse_decimal(value) when is_number(value), do: decimal(value)
  def parse_decimal(_value), do: decimal("0")

  def decimal_from_string(nil), do: nil

  def decimal_from_string(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  def decimal_from_string(%Decimal{} = value), do: value
  def decimal_from_string(_value), do: nil

  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)

  def decimal_to_wei(%Decimal{} = value) do
    scaled = Decimal.mult(value, Decimal.new("1000000"))

    if Decimal.equal?(scaled, Decimal.round(scaled, 0)) do
      {:ok, scaled |> Decimal.round(0) |> Decimal.to_integer()}
    else
      {:error, :invalid_amount_precision}
    end
  end

  def decimal_price_to_q96(%Decimal{} = value) do
    scaled = Decimal.mult(value, Decimal.new("79228162514264337593543950336"))

    if Decimal.equal?(scaled, Decimal.round(scaled, 0)) do
      {:ok, scaled |> Decimal.round(0) |> Decimal.to_integer()}
    else
      {:ok, scaled |> Decimal.round(0) |> Decimal.to_integer()}
    end
  rescue
    _ -> {:error, :invalid_max_price}
  end

  def q96_price_to_string(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new("79228162514264337593543950336"))
    |> Decimal.round(12)
    |> Decimal.to_string(:normal)
  end

  def q96_to_decimal(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new("79228162514264337593543950336"))
    |> Decimal.round(12)
  end

  def token_units_to_string(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new("1000000000000000000"))
    |> Decimal.round(6)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp wei_to_string(value) when is_integer(value) and value >= 0 do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new("1000000"))
    |> Decimal.round(6)
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp wei_to_float(value) when is_integer(value), do: value / 1.0e6

  def decimal_string(value, places \\ 4)

  def decimal_string(%Decimal{} = value, places) do
    value
    |> Decimal.round(places)
    |> Decimal.to_string(:normal)
  end

  def decimal_string(nil, _places), do: "0"
end
