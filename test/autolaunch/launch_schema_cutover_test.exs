defmodule Autolaunch.LaunchSchemaCutoverTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Launch
  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Bid
  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @sepolia_network "base-sepolia"
  @sepolia_chain_id 84_532
  @invalid_network "ethereum-mainnet"
  @invalid_chain_id 1
  @mainnet_network "base-mainnet"
  @mainnet_chain_id 8_453

  setup do
    previous_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(previous_launch, chain_id: @sepolia_chain_id)
    )

    on_exit(fn ->
      Application.put_env(:autolaunch, :launch, previous_launch)
    end)

    :ok
  end

  test "launch schemas reject non-base launch values before persistence" do
    assert invalid_field_errors(
             Job.create_changeset(%Job{}, job_attrs(@invalid_network, @invalid_chain_id))
           )

    assert invalid_field_errors(
             Auction.changeset(%Auction{}, auction_attrs(@invalid_network, @invalid_chain_id))
           )

    assert invalid_field_errors(
             Bid.create_changeset(%Bid{}, bid_attrs(@invalid_network, @invalid_chain_id))
           )
  end

  test "database defaults are sepolia only" do
    assert column_default("autolaunch_jobs", "network") =~ @sepolia_network
    assert column_default("autolaunch_jobs", "chain_id") =~ Integer.to_string(@sepolia_chain_id)
    assert column_default("autolaunch_auctions", "network") =~ @sepolia_network

    assert column_default("autolaunch_auctions", "chain_id") =~
             Integer.to_string(@sepolia_chain_id)

    assert column_default("autolaunch_bids", "network") =~ @sepolia_network
    assert column_default("autolaunch_bids", "chain_id") =~ Integer.to_string(@sepolia_chain_id)
  end

  test "database allows Base-family inserts for launch tables" do
    assert_insert_allowed(insert_job_row(@mainnet_network, @mainnet_chain_id))
    assert_insert_allowed(insert_auction_row(@mainnet_network, @mainnet_chain_id))
    assert_insert_allowed(insert_bid_row(@mainnet_network, @mainnet_chain_id))
  end

  test "migration delete rule removes non-sepolia rows from a fixture table" do
    Repo.query!("DROP TABLE IF EXISTS temp_launch_cutover_jobs")

    Repo.query!("""
    CREATE TEMP TABLE temp_launch_cutover_jobs (
      LIKE autolaunch_jobs INCLUDING DEFAULTS
    ) ON COMMIT DROP
    """)

    Repo.query!(
      """
      INSERT INTO temp_launch_cutover_jobs (
        job_id, owner_address, agent_id, agent_safe_address,
        network, chain_id, status, step, total_supply, message, siwa_nonce, siwa_signature,
        issued_at, inserted_at, updated_at
      ) VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, NOW(), NOW()),
        ($14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25, $26, NOW(), NOW())
      """,
      [
        "job_sepolia",
        "0x1111111111111111111111111111111111111111",
        "84532:42",
        "0x1111111111111111111111111111111111111111",
        @sepolia_network,
        @sepolia_chain_id,
        "queued",
        "queued",
        "1000",
        "signed",
        "nonce-sepolia",
        "sig",
        DateTime.utc_now(),
        "job_mainnet",
        "0x2222222222222222222222222222222222222222",
        "84532:99",
        "0x2222222222222222222222222222222222222222",
        @mainnet_network,
        @mainnet_chain_id,
        "queued",
        "queued",
        "1000",
        "signed",
        "nonce-mainnet",
        "sig",
        DateTime.utc_now()
      ]
    )

    Repo.query!(
      """
      DELETE FROM temp_launch_cutover_jobs
      WHERE network IS DISTINCT FROM $1
         OR chain_id IS DISTINCT FROM $2
      """,
      [@sepolia_network, @sepolia_chain_id]
    )

    assert %Postgrex.Result{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM temp_launch_cutover_jobs WHERE network = $1", [
               @sepolia_network
             ])

    assert %Postgrex.Result{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM temp_launch_cutover_jobs WHERE network = $1", [
               @mainnet_network
             ])
  end

  test "job reads stay scoped to the active launch chain" do
    {:ok, _} = insert_active_chain_job("job_active_chain", @sepolia_network, @sepolia_chain_id)
    {:ok, _} = insert_active_chain_job("job_other_chain", @mainnet_network, @mainnet_chain_id)

    assert {:ok, %{job: %{job_id: "job_active_chain", chain_id: @sepolia_chain_id}}} =
             Launch.get_job_response("job_active_chain")

    assert {:error, :not_found} = Launch.get_job_response("job_other_chain")
  end

  defp invalid_field_errors(changeset) do
    refute changeset.valid?
    error_keys = Keyword.keys(changeset.errors)
    assert :network in error_keys
    assert :chain_id in error_keys
    true
  end

  defp assert_insert_allowed(%Postgrex.Result{}), do: true

  defp insert_active_chain_job(job_id, network, chain_id) do
    %Job{}
    |> Job.create_changeset(%{
      job_id: job_id,
      owner_address: "0x1111111111111111111111111111111111111111",
      agent_id: "#{chain_id}:42",
      token_name: "Atlas Coin",
      token_symbol: "ATLAS",
      agent_safe_address: "0x1111111111111111111111111111111111111111",
      network: network,
      chain_id: chain_id,
      status: "ready",
      step: "ready",
      total_supply: "1000",
      message: "signed",
      siwa_nonce: "nonce-#{job_id}",
      siwa_signature: "sig",
      issued_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp job_attrs(network, chain_id) do
    %{
      job_id: "job_schema_cutover",
      owner_address: "0x1111111111111111111111111111111111111111",
      agent_id: "84532:42",
      token_name: "Atlas Coin",
      token_symbol: "ATLAS",
      agent_safe_address: "0x1111111111111111111111111111111111111111",
      network: network,
      chain_id: chain_id,
      status: "queued",
      step: "queued",
      total_supply: "1000",
      message: "signed",
      siwa_nonce: "nonce",
      siwa_signature: "sig",
      issued_at: DateTime.utc_now()
    }
  end

  defp auction_attrs(network, chain_id) do
    %{
      source_job_id: "job_schema_cutover",
      agent_id: "84532:42",
      agent_name: "Atlas",
      owner_address: "0x1111111111111111111111111111111111111111",
      auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      token_address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      network: network,
      chain_id: chain_id,
      status: "active",
      started_at: DateTime.utc_now()
    }
  end

  defp bid_attrs(network, chain_id) do
    %{
      bid_id: "bid_schema_cutover",
      owner_address: "0x1111111111111111111111111111111111111111",
      auction_id: "auc_schema_cutover",
      auction_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      agent_id: "84532:42",
      agent_name: "Atlas",
      network: network,
      chain_id: chain_id,
      amount: Decimal.new("1.0"),
      max_price: Decimal.new("0.0010"),
      current_clearing_price: Decimal.new("0.0010"),
      current_status: "active"
    }
  end

  defp column_default(table, column) do
    %{rows: [[default]]} =
      Repo.query!(
        """
        SELECT column_default
        FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    default
  end

  defp insert_job_row(network, chain_id) do
    Repo.query!(
      """
      INSERT INTO autolaunch_jobs (
        job_id, owner_address, agent_id, agent_safe_address,
        network, chain_id, status, step, total_supply, message, siwa_nonce, siwa_signature,
        issued_at, inserted_at, updated_at
      ) VALUES (
        'job_test',
        '0x1111111111111111111111111111111111111111',
        '84532:42',
        '0x1111111111111111111111111111111111111111',
        $1,
        $2,
        'queued',
        'queued',
        '1000',
        'signed',
        'nonce',
        'sig',
        NOW(),
        NOW(),
        NOW()
      )
      """,
      [network, chain_id]
    )
  end

  defp insert_auction_row(network, chain_id) do
    Repo.query!(
      """
      INSERT INTO autolaunch_auctions (
        source_job_id, agent_id, agent_name, owner_address, auction_address,
        network, chain_id, status, started_at, inserted_at, updated_at
      ) VALUES (
        'job_test',
        '84532:42',
        'Atlas',
        '0x1111111111111111111111111111111111111111',
        '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        $1,
        $2,
        'active',
        NOW(),
        NOW(),
        NOW()
      )
      """,
      [network, chain_id]
    )
  end

  defp insert_bid_row(network, chain_id) do
    Repo.query!(
      """
      INSERT INTO autolaunch_bids (
        bid_id, owner_address, auction_id, agent_id, amount, max_price,
        current_clearing_price, current_status, chain_id, network, inserted_at, updated_at
      ) VALUES (
        'bid_test',
        '0x1111111111111111111111111111111111111111',
        'auc_test',
        '84532:42',
        1.0,
        0.0010,
        0.0010,
        'active',
        $2,
        $1,
        NOW(),
        NOW()
      )
      """,
      [network, chain_id]
    )
  end
end
