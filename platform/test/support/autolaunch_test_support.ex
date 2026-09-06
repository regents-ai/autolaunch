defmodule Autolaunch.TestSupport do
  @moduledoc false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  @doc "Projects one Auction through `project_lab_auction` as the system actor."
  def project_auction(opts \\ []) do
    opts = Map.new(opts)

    Autolaunch.project_lab_auction!(
      %{
        projection_id: Map.get(opts, :id) || Ash.UUID.generate(),
        title: Map.get(opts, :title, "Auction"),
        summary: Map.get(opts, :summary),
        token_symbol: Map.get(opts, :symbol),
        creator_human_account_id:
          Map.get(opts, :creator_human_account_id) || register_creator!().id,
        featured: Map.get(opts, :featured, false),
        state: Map.get(opts, :state, :created),
        opened_at: Map.get(opts, :opened_at),
        auction_address: Map.get(opts, :address),
        current_clearing_price: Map.get(opts, :current_clearing_price, "1"),
        website: Map.get(opts, :website),
        image: Map.get(opts, :image),
        treasury_address: Map.get(opts, :treasury_address)
      },
      actor: %System{}
    )
  end

  @doc "Projects one Token through `project_lab_token` as the system actor."
  def project_token(opts) do
    opts = Map.new(opts)

    Autolaunch.project_lab_token!(
      %{
        auction_id: Map.fetch!(opts, :auction_id),
        subject_id: Map.get(opts, :subject_id),
        name: Map.get(opts, :name, "Token"),
        symbol: Map.get(opts, :symbol, "TKN"),
        summary: Map.get(opts, :summary),
        graduated_at: Map.get(opts, :graduated_at),
        top_rank: Map.get(opts, :top_rank),
        treasury_address: Map.get(opts, :treasury_address)
      },
      actor: %System{}
    )
  end

  @doc "Projects one Subject through `project_lab_subject` as the system actor."
  def project_subject(opts \\ []) do
    opts = Map.new(opts)

    Autolaunch.project_lab_subject!(
      %{
        subject_id: Map.get(opts, :subject_id, "subject:resource"),
        subject_kind: Map.get(opts, :subject_kind, "agent"),
        chain_id: Map.get(opts, :chain_id, 8453),
        token_address:
          Map.get(opts, :token_address, "0x3333333333333333333333333333333333333333"),
        splitter_address:
          Map.get(opts, :splitter_address, "0x4444444444444444444444444444444444444444"),
        ingress_address:
          Map.get(opts, :ingress_address, "0x5555555555555555555555555555555555555555"),
        treasury_address:
          Map.get(opts, :treasury_address, "0x6666666666666666666666666666666666666666"),
        factory_address:
          Map.get(opts, :factory_address, "0x7777777777777777777777777777777777777777"),
        creator_address:
          Map.get(opts, :creator_address, "0x8888888888888888888888888888888888888888"),
        staker_pool_bps: Map.get(opts, :staker_pool_bps, 1500),
        protocol_skim_bps_snapshot: Map.get(opts, :protocol_skim_bps_snapshot, 250),
        current_protocol_skim_bps: Map.get(opts, :current_protocol_skim_bps, 200),
        protocol_fee_usdc_total_raw: Map.get(opts, :protocol_fee_usdc_total_raw, "12000000"),
        regent_emission_total_raw:
          Map.get(opts, :regent_emission_total_raw, "3400000000000000000"),
        pending_buyback_usdc_raw: Map.get(opts, :pending_buyback_usdc_raw, "5000000"),
        canonical_receiver_address: Map.get(opts, :canonical_receiver_address)
      },
      actor: %System{}
    )
  end

  @doc "Projects one LaunchJob through `project_lab_launch` as the system actor."
  def project_launch(opts \\ []) do
    opts = Map.new(opts)

    Autolaunch.project_lab_launch!(
      %{
        job_id: Map.get(opts, :job_id, "launch:resource"),
        status: Map.get(opts, :status, "running"),
        step: Map.get(opts, :step, "deploy_token"),
        agent_id: Map.get(opts, :agent_id, "agent:resource"),
        agent_name: Map.get(opts, :agent_name, "Resource Agent"),
        token_name: Map.get(opts, :token_name, "Resource Token"),
        token_symbol: Map.get(opts, :token_symbol, "RSC"),
        chain_id: Map.get(opts, :chain_id, 8453),
        auction_id: Map.get(opts, :auction_id),
        agent_safe_address:
          Map.get(opts, :agent_safe_address, "0x1111111111111111111111111111111111111111"),
        auction_address:
          Map.get(opts, :auction_address, "0x2222222222222222222222222222222222222222"),
        token_address:
          Map.get(opts, :token_address, "0x3333333333333333333333333333333333333333"),
        hook_address: Map.get(opts, :hook_address, "0x4444444444444444444444444444444444444444"),
        revenue_share_splitter_address:
          Map.get(
            opts,
            :revenue_share_splitter_address,
            "0x5555555555555555555555555555555555555555"
          ),
        treasury_address: Map.get(opts, :treasury_address),
        started_at: Map.get(opts, :started_at),
        finished_at: Map.get(opts, :finished_at)
      },
      actor: %System{}
    )
  end

  @doc "Inserts one auction row beneath the resource so listing tests can prove R10."
  def insert_null_creator_auction! do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # The resource and migration refuse NULL; AE6 still has to prove a
    # beneath-the-resource row is filtered from every public read.
    {:ok, _} =
      Autolaunch.Repo.query(
        "ALTER TABLE auctions ALTER COLUMN creator_human_account_id DROP NOT NULL"
      )

    {1, nil} =
      Autolaunch.Repo.insert_all("auctions", [
        %{
          id: Ecto.UUID.dump!(id),
          title: "Hidden",
          featured: true,
          state: "active",
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  def register_creator! do
    nonce = Elixir.System.unique_integer([:positive])
    wallet = "0x" <> String.pad_leading(Integer.to_string(nonce, 16), 40, "0")

    Accounts.register_verified!(
      "did:privy:project-auction:#{nonce}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end

  @doc "Completes one verified profile or company X connection for a Human account."
  def verify_x!(account, role, opts) do
    opts = Map.new(opts)
    username = Map.fetch!(opts, :username)
    actor = %Human{human_account_id: account.id}

    connection =
      Accounts.begin_x_connection_attempt!(
        %{
          role: role,
          attempt_state: "state-#{Ash.UUID.generate()}",
          attempt_verifier: "verifier-#{Ash.UUID.generate()}",
          attempt_generation: Ash.UUID.generate(),
          attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second),
          intent_sequence: 1,
          intent_generation: Ash.UUID.generate()
        },
        actor: actor
      )

    Accounts.complete_x_connection_attempt!(
      connection,
      %{
        x_user_id: Map.get(opts, :x_user_id, "x-#{role}-#{account.id}"),
        username: username,
        display_name: Map.get(opts, :display_name, username),
        avatar_url: Map.get(opts, :avatar_url),
        verified_at: Map.get(opts, :verified_at, DateTime.utc_now()),
        next_generation: Ash.UUID.generate()
      },
      actor: actor
    )
  end
end
