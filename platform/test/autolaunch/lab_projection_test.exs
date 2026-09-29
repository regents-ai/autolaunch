defmodule Autolaunch.LabProjectionTest do
  use AutolaunchWeb.ConnCase, async: false

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}

  alias Autolaunch.{
    Auction,
    Bid,
    LabProjection,
    LaunchDraft,
    LaunchJob,
    LaunchOperation,
    Subject,
    Token
  }

  @domain Autolaunch
  @actor %System{}
  @wallet "0x1111111111111111111111111111111111111111"
  @factory "0x2222222222222222222222222222222222222222"
  @hook "0x3333333333333333333333333333333333333333"
  @regent "0x4444444444444444444444444444444444444444"
  @auction "0x5555555555555555555555555555555555555555"
  @subject "0x6666666666666666666666666666666666666666"
  @escrow "0x7777777777777777777777777777777777777777"
  @treasury "0x8888888888888888888888888888888888888888"
  @splitter "0x9999999999999999999999999999999999999999"
  @receiver "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "a verified local launch and bid project once under exact deterministic identities" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())

    [auction] = all(Auction)
    [subject] = all(Subject)
    [launch] = all(LaunchJob)

    assert auction.id == LabProjection.auction_id(@auction)
    assert auction.state == :active
    assert auction.auction_address == @auction
    assert auction.treasury_address == @treasury
    assert auction.quote_token_address == @regent

    assert subject.subject_id == LabProjection.subject_identity(@subject)
    assert subject.chain_id == 31_337
    assert subject.token_address == @subject
    assert subject.treasury_address == @treasury

    assert launch.job_id == LabProjection.launch_identity("17")
    assert launch.auction_id == auction.id
    assert launch.chain_id == 31_337
    assert launch.token_symbol == "LOCAL"
    assert launch.hook_address == @hook

    assert :ok = LabProjection.project_bid(bid_operation(auction.id), bid_result())
    assert :ok = LabProjection.project_bid(bid_operation(auction.id), bid_result())

    [bid] = all(Bid)
    assert bid.bid_id == LabProjection.bid_identity(@auction, "9")
    assert bid.auction_id == auction.id
    assert bid.owner_address == @wallet
    assert bid.auction_address == @auction
    assert bid.onchain_bid_id == "9"
  end

  test "late sibling receipts preserve exited/failed canonical effects" do
    assert_receipt_replay_preserves("exited", "failed")
  end

  test "late sibling receipts preserve claimed/graduated canonical effects" do
    assert_receipt_replay_preserves("claimed", "graduated")
  end

  defp assert_receipt_replay_preserves(bid_state, auction_state) do
    {launch, bid, opts} = receipt_parents()
    launch_a = issued(:launch, launch)
    launch_b = issued(:launch, launch)
    bid_a = issued(:bid, bid)
    bid_b = issued(:bid, bid)
    verify_receipt(:launch, launch, launch_a, opts)
    verify_receipt(:bid, bid, bid_a, opts)
    advance_position(bid_state, auction_state)
    before = projection_rows()

    verify_receipt(:bid, bid, bid_b, opts)
    verify_receipt(:launch, launch, launch_b, opts)
    assert projection_rows() == before
    attempts = Ash.read!(Autolaunch.WalletAttempt, actor: @actor)
    assert length(attempts) == 4
    assert Enum.all?(attempts, &(&1.state == :confirmed and &1.resolved_at))
    assert Enum.all?(attempts, &(&1.evidence["verification"] == "confirmed"))
    assert Enum.count(attempts, &(&1.result == bid_result())) == 2
    assert Enum.count(attempts, &(&1.result == launch_result())) == 2
  end

  test "backfilled settled legacy parents adopt effects without rewriting lifecycle rows" do
    {launch, bid, opts} = receipt_parents()
    assert :ok = LabProjection.project_launch(launch, launch_result())
    assert :ok = LabProjection.project_bid(bid, bid_result())
    advance_position("claimed", "graduated")
    hash = receipt_hash()

    Autolaunch.Repo.query!(
      "UPDATE launch_operations SET state = 'chain_verified', terminal_at = now(), launch_transaction_hash = $1, result = $2 WHERE id = $3",
      [hash, launch_result(), Ecto.UUID.dump!(launch.id)]
    )

    Autolaunch.Repo.query!(
      "UPDATE bid_operations SET state = 'confirmed', terminal_at = now(), bid_transaction_hash = $1, onchain_bid_id = '9' WHERE id = $2",
      [hash, Ecto.UUID.dump!(bid.id)]
    )

    parents = fn ->
      for table <- ["bid_operations", "launch_operations"],
          do: Autolaunch.Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows
    end

    before_parents = parents.()
    before_effects = projection_rows()
    migration = File.read!("priv/repo/migrations/20260907175423_wallet_attempts.exs")

    {_, statements} =
      Macro.prewalk(Code.string_to_quoted!(migration), [], fn
        {:execute, _, [sql]} = node, acc when is_binary(sql) -> {node, [sql | acc]}
        node, acc -> {node, acc}
      end)

    Enum.each(statements, &Autolaunch.Repo.query!/1)
    attempts = Ash.read!(Autolaunch.WalletAttempt, actor: @actor)
    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.legacy and &1.state == :submitted))

    for attempt <- attempts do
      parent = if attempt.step == :bid, do: bid, else: launch
      verify_receipt(attempt.step, parent, attempt, opts)
    end

    assert parents.() == before_parents
    assert projection_rows() == before_effects

    reconciled = Ash.read!(Autolaunch.WalletAttempt, actor: @actor)
    assert Enum.all?(reconciled, &(&1.state == :confirmed))
    assert Enum.all?(reconciled, &(&1.evidence["dispatch_time"] == "unknown"))
  end

  defp receipt_parents do
    account =
      Accounts.register_verified!(
        "did:privy:receipt-#{Elixir.System.unique_integer([:positive])}",
        @wallet,
        [@wallet],
        actor: @actor
      )

    launch_attrs = launch_operation(account.id)
    account_id = account.id

    {:ok, :bind, claim} =
      Accounts.SessionAuthority.sign_in(Accounts.SessionAuthority.bootstrap(), account_id)

    actor = %Human{human_account_id: account_id}

    opts = [
      actor: actor,
      context: %{session_lease: %{lineage: claim.lineage, account_id: account_id}}
    ]

    draft =
      Autolaunch.create_launch_draft!(%{"name" => "Receipt", "symbol" => "RCPT"}, actor: actor)

    launch =
      receipt_parent(LaunchOperation, launch_attrs.envelope, account_id, :launch,
        launch_draft_id: draft.id
      )

    # The canonical auction exists before a bid review can be issued.
    assert :ok = LabProjection.project_launch(launch, launch_result())

    bid =
      receipt_parent(
        Autolaunch.BidOperation,
        bid_operation(LabProjection.auction_id(@auction)).envelope,
        account_id,
        :bid,
        auction_id: LabProjection.auction_id(@auction)
      )

    {launch, bid, opts}
  end

  defp receipt_parent(resource, envelope, account_id, step, attrs) do
    envelope = put_in(envelope, ["arguments", "steps"], [%{"step" => Atom.to_string(step)}])

    Ash.Seed.seed!(
      resource,
      Map.merge(Map.new(attrs), %{
        action_id: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        envelope: envelope,
        human_account_id: account_id,
        signer: @wallet,
        step: step,
        state: :submitted
      })
    )
  end

  defp issued(kind, op) do
    key = if kind == :bid, do: :bid_operation_id, else: :launch_operation_id

    Autolaunch.WalletAttempt
    |> Ash.Changeset.for_create(
      :dispatch,
      %{
        key => op.id,
        :step => kind,
        :envelope => op.envelope,
        :state => :submitted,
        :transaction_hash => receipt_hash(),
        :legacy => false
      },
      actor: @actor
    )
    |> Ash.create!(actor: @actor)
  end

  defp verify_receipt(kind, parent, attempt, opts) do
    if kind == :bid do
      Autolaunch.BidFixture.install(
        outcomes: %{bid: %{outcome: :confirmed, result: bid_result()}}
      )
    else
      Autolaunch.LaunchFixture.install(
        outcomes: %{launch: %{outcome: :confirmed, result: launch_result()}}
      )
    end

    assert {:ok, %{attempt: %{state: :confirmed}}} =
             Autolaunch.verify_wallet_press(kind, parent.action_id, attempt.id, opts)
  end

  defp advance_position(bid_state, auction_state) do
    assert :ok =
             LabProjection.project_position(one(Bid), %{
               "bid_status" => bid_state,
               "exited" => true,
               "claimed" => bid_state == "claimed",
               "auction_state" => auction_state,
               "current_clearing_price" => "7.125",
               "subject" => @subject,
               "splitter" => @splitter,
               "receiver" => @receiver
             })
  end

  defp projection_rows do
    for table <- ["bids", "auctions", "subjects", "launch_jobs", "tokens"],
        do: Autolaunch.Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows
  end

  defp receipt_hash, do: "0x" <> String.duplicate("ab", 32)

  test "launch presentation and creator come only from the immutable operation envelope" do
    account = account!("immutable-presentation")
    actor = %Human{human_account_id: account.id}

    draft =
      Autolaunch.create_launch_draft!(
        %{
          "name" => "Mutable draft",
          "symbol" => "MUT",
          "description" => "Before review",
          "website" => "https://mutable.example/before",
          "required_regent_raised" => "1"
        },
        actor: actor
      )

    operation =
      Ash.Seed.seed!(LaunchOperation, %{
        action_id: String.duplicate("a", 64),
        envelope: launch_operation(account.id).envelope,
        signer: @wallet,
        step: :launch,
        state: :submitted,
        human_account_id: account.id,
        launch_draft_id: draft.id
      })

    assert {:ok, %LaunchDraft{}} =
             Autolaunch.autosave_launch_token_details(
               draft,
               %{
                 "name" => "Changed after wallet review",
                 "symbol" => "NEW",
                 "description" => "This mutable copy must never project.",
                 "website" => "https://mutable.example/after",
                 "required_regent_raised" => "2"
               },
               actor: actor
             )

    assert :ok = LabProjection.project_launch(operation, launch_result())

    auction = one(Auction)
    assert auction.title == "Local Regent"
    assert auction.summary == "A local fork launch."
    assert auction.token_symbol == "LOCAL"
    assert auction.website == "https://example.test/local"
    assert auction.image == "https://example.test/local.png"
    assert auction.creator_human_account_id == account.id
  end

  test "out-of-order position receipts cannot rewind claimed or graduated chain state" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    auction_id = LabProjection.auction_id(@auction)
    assert :ok = LabProjection.project_bid(bid_operation(auction_id), bid_result())
    [bid] = all(Bid)

    exit = %{
      "bid_status" => "exited",
      "exited" => true,
      "claimed" => false,
      "current_clearing_price" => "1.25"
    }

    assert :ok = LabProjection.project_position(bid, exit)
    exited = one(Bid)
    assert exited.status == "exited"
    assert exited.exited_at
    refute exited.claimed_at

    assert :ok = LabProjection.project_position(exited, exit)
    replayed_exit = one(Bid)
    assert replayed_exit.exited_at == exited.exited_at

    claim = %{
      "bid_status" => "claimed",
      "exited" => true,
      "claimed" => true
    }

    assert :ok = LabProjection.project_position(replayed_exit, claim)
    claimed = one(Bid)
    assert claimed.status == "claimed"
    assert claimed.claimed_at

    assert :ok = LabProjection.project_position(replayed_exit, exit)
    late_exit = one(Bid)
    assert late_exit.status == "claimed"
    assert late_exit.claimed_at == claimed.claimed_at

    graduated = %{
      "auction_state" => "graduated",
      "subject" => @subject,
      "splitter" => @splitter,
      "receiver" => @receiver,
      "token_symbol" => "DIVERGENT"
    }

    assert :ok = LabProjection.project_position(late_exit, graduated)

    final_bid = one(Bid)
    final_auction = one(Auction)
    final_subject = one(Subject)
    final_launch = one(LaunchJob)
    final_token = one(Token)

    assert final_bid.status == "claimed"
    assert final_bid.exited_at == exited.exited_at
    assert final_auction.state == :graduated
    assert final_subject.splitter_address == @splitter
    assert final_subject.canonical_receiver_address == @receiver
    assert final_launch.status == "complete"
    assert final_launch.step == "graduated"
    assert final_token.auction_id == final_auction.id
    assert final_token.subject_id == final_subject.subject_id
    assert final_token.symbol == "LOCAL"

    finished_at = final_launch.finished_at
    graduated_at = final_token.graduated_at

    assert :ok = LabProjection.project_position(replayed_exit, exit)
    assert one(Bid).status == "claimed"
    assert one(Auction).state == :graduated
    assert one(LaunchJob).status == "complete"

    assert :ok = LabProjection.project_position(final_bid, graduated)
    assert one(LaunchJob).finished_at == finished_at
    assert one(Token).graduated_at == graduated_at
  end

  test "position projection locks the stored bid and auction before joining chain state" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    auction_id = LabProjection.auction_id(@auction)
    assert :ok = LabProjection.project_bid(bid_operation(auction_id), bid_result())
    [bid] = all(Bid)

    emitted =
      captured(fn ->
        assert :ok =
                 LabProjection.project_position(bid, %{
                   "bid_status" => "exited",
                   "exited" => true,
                   "claimed" => false
                 })
      end)

    assert Enum.any?(selects(emitted, "bids"), &String.contains?(&1, "FOR UPDATE"))
    assert Enum.any?(selects(emitted, "auctions"), &String.contains?(&1, "FOR UPDATE"))
  end

  test "independent SQL initializers adopt lifecycle state committed by their conflicting writer" do
    # These tasks explicitly check out unboxed connections, not the ConnCase's
    # shared sandbox transaction. PostgreSQL must report the real blocking edge.
    operation =
      unboxed(fn ->
        assert Autolaunch.Repo.query!(
                 "SELECT id FROM auctions WHERE id = $1",
                 [Ecto.UUID.dump!(LabProjection.auction_id(@auction))]
               ).rows == []

        assert Autolaunch.Repo.query!("SELECT id FROM subjects WHERE subject_id = $1", [
                 LabProjection.subject_identity(@subject)
               ]).rows == []

        assert Autolaunch.Repo.query!("SELECT id FROM launch_jobs WHERE job_id = $1", [
                 LabProjection.launch_identity("17")
               ]).rows == []

        launch_operation()
      end)

    on_exit(fn -> unboxed(fn -> cleanup_projection(operation.human_account_id) end) end)
    parent = self()

    first =
      Task.async(fn ->
        unboxed(fn ->
          Autolaunch.Repo.transaction(fn ->
            assert :ok = LabProjection.project_launch(operation, launch_result())

            assert :ok =
                     LabProjection.project_bid(
                       bid_operation(LabProjection.auction_id(@auction)),
                       bid_result()
                     )

            advance_position("claimed", "graduated")
            send(parent, {:projection_held, backend_pid(), projection_rows()})

            receive do
              :commit_projection -> :ok
            after
              5_000 -> flunk("projection writer was not released")
            end
          end)
        end)
      end)

    assert_receive {:projection_held, first_pid, before}, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:projection_contender, backend_pid()})
          assert :ok = LabProjection.project_launch(operation, launch_result())

          assert :ok =
                   LabProjection.project_bid(
                     bid_operation(LabProjection.auction_id(@auction)),
                     bid_result()
                   )

          projection_rows()
        end)
      end)

    assert_receive {:projection_contender, second_pid}, 5_000
    assert first_pid != second_pid
    assert_blocked(second_pid, first_pid, 200)
    send(first.pid, :commit_projection)
    assert {:ok, :ok} = Task.await(first, 5_000)
    assert Task.await(second, 5_000) == before
    assert unboxed(fn -> projection_rows() end) == before
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Autolaunch.Repo, fun)

  defp backend_pid do
    [[pid]] = Autolaunch.Repo.query!("SELECT pg_backend_pid()").rows
    pid
  end

  defp assert_blocked(_contender, _holder, 0), do: flunk("no independent SQL conflict observed")

  defp assert_blocked(contender, holder, tries) do
    [[blocked]] =
      unboxed(fn ->
        Autolaunch.Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [holder, contender]).rows
      end)

    unless blocked do
      receive do
      after
        5 -> assert_blocked(contender, holder, tries - 1)
      end
    end
  end

  defp cleanup_projection(account_id) do
    auction_id = Ecto.UUID.dump!(LabProjection.auction_id(@auction))

    for table <- ["bids", "tokens", "launch_jobs"] do
      Autolaunch.Repo.query!("DELETE FROM #{table} WHERE auction_id = $1", [auction_id])
    end

    Autolaunch.Repo.query!("DELETE FROM subjects WHERE subject_id = $1", [
      LabProjection.subject_identity(@subject)
    ])

    Autolaunch.Repo.query!("DELETE FROM auctions WHERE id = $1", [auction_id])
    Autolaunch.Repo.query!("DELETE FROM human_accounts WHERE id = $1", [account_id])
  end

  test "the full uint256 Q96 effective price fits the canonical bid without rounding" do
    assert :ok = LabProjection.project_launch(launch_operation(), launch_result())
    maximum = Integer.pow(2, 256) - 1
    exact = Decimal.new(1, maximum * Integer.pow(5, 96), -96) |> Decimal.to_string(:normal)
    assert byte_size(exact) == 146

    operation =
      put_in(
        bid_operation(LabProjection.auction_id(@auction)),
        [:envelope, "arguments", "max_price"],
        exact
      )

    assert :ok = LabProjection.project_bid(operation, bid_result())
    assert one(Bid).max_price == exact
  end

  test "a later invalid resource refuses and rolls the whole launch projection back" do
    operation = put_in(launch_operation(), [:envelope, "arguments", "symbol"], "not-valid")

    assert {:error, _reason} = LabProjection.project_launch(operation, launch_result())
    assert all(Auction) == []
    assert all(Subject) == []
    assert all(LaunchJob) == []
  end

  defp launch_operation(human_account_id \\ nil) do
    %{
      human_account_id: human_account_id || account!("launch-op").id,
      envelope: %{
        "chain_id" => 31_337,
        "expected_signer" => @wallet,
        "metadata" => %{
          "lab" => %{
            "rpc_url" => "http://127.0.0.1:49713",
            "chain_id" => 31_337,
            "addresses" => %{"hook" => @hook}
          }
        },
        "arguments" => %{
          "name" => "Local Regent",
          "symbol" => "LOCAL",
          "description" => "A local fork launch.",
          "website" => "https://example.test/local",
          "image" => "https://example.test/local.png",
          "regent" => @regent,
          "factory" => @factory
        }
      }
    }
  end

  defp launch_result do
    %{
      "launch_id" => "17",
      "subject" => @subject,
      "auction" => @auction,
      "escrow" => @escrow,
      "treasury" => @treasury,
      "start_block" => "100",
      "end_block" => "200"
    }
  end

  defp bid_operation(auction_id) do
    %{
      envelope: %{
        "chain_id" => 31_337,
        "expected_signer" => @wallet,
        "to" => @auction,
        "metadata" => %{
          "lab" => %{
            "rpc_url" => "http://127.0.0.1:49713",
            "chain_id" => 31_337,
            "addresses" => %{"regent" => @regent}
          }
        },
        "arguments" => %{
          "auction_id" => auction_id,
          "amount" => "100",
          "max_price" => "2.5"
        }
      }
    }
  end

  defp bid_result do
    %{
      "onchain_bid_id" => "9",
      "current_clearing_price" => "1"
    }
  end

  defp one(resource) do
    case all(resource) do
      [record] -> record
      records -> flunk("expected one #{inspect(resource)}, got #{length(records)}")
    end
  end

  defp all(resource) do
    action = if resource == Bid, do: :mine, else: :read

    # Projection tests inspect raw stored rows with the trusted System actor.
    resource
    |> Ash.Query.for_read(action, %{}, domain: @domain, actor: @actor, authorize?: false)
    |> then(fn query ->
      if resource == Auction,
        do: Ash.Query.filter(query, not is_nil(auction_address)),
        else: query
    end)
    |> Ash.read!(domain: @domain)
  end

  defp captured(work) do
    parent = self()
    handler = "lab-projection-sql-#{Elixir.System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:autolaunch, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if self() == owner, do: send(owner, {:sql, metadata[:source], metadata.query})
      end,
      parent
    )

    work.()
    :telemetry.detach(handler)
    drained([])
  end

  defp drained(collected) do
    receive do
      {:sql, source, query} -> drained([{source, query} | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  defp selects(emitted, table) do
    for {^table, query} <- emitted, String.starts_with?(query, "SELECT"), do: query
  end

  defp account!(suffix) do
    nonce = Elixir.System.unique_integer([:positive])
    wallet = "0x" <> String.pad_leading(Integer.to_string(nonce, 16), 40, "0")

    Accounts.register_verified!(
      "did:privy:lab-projection:#{suffix}:#{nonce}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end
end
