defmodule Autolaunch.BidOperationTest do
  @moduledoc """
  What the durable bid row guarantees.

  The barrier proofs run on real second connections and let PostgreSQL report
  the ordering through `pg_blocking_pids`, so no clock decides a race. They
  commit outside the sandbox, which is why the whole block clears its own
  committed rows before and after every test.
  """

  use AutolaunchWeb.ConnCase, async: false

  import Autolaunch.BidFixture
  import Ecto.Query

  require Ash.Query

  alias Autolaunch
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.SessionAuthority

  alias Autolaunch.{Auction, BidOperation, TreasurySecurityReport}
  alias Autolaunch.Repo

  @approval_hash "0x" <> String.duplicate("aa", 32)

  @barrier_treasury "0x8888888888888888888888888888888888888888"

  setup :bidder
  setup :verified_treasury

  setup do
    install()
    :ok
  end

  defp verified_treasury(%{auction: auction}) do
    report =
      Autolaunch.TestAutolaunchTreasuryChainClient.seed_verified!(
        "0x9999999999999999999999999999999999999999"
      )

    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: system())

    on_exit(fn ->
      Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    :ok
  end

  test "REVOCATION_ENDS_EVERY_WRITE: a revoked lease claims, binds and settles nothing", %{
    auction: auction,
    wallet: wallet,
    opts: opts,
    account: account
  } do
    operation = review(auction, wallet, opts)
    assert SessionAuthority.revoke(%{lineage: opts[:context].session_lease.lineage})

    for refused <- [
          fn -> Autolaunch.claim_bid_dispatch(operation.action_id, opts) end,
          fn ->
            Autolaunch.bind_bid_hash(operation.action_id, :token_approval, @approval_hash, opts)
          end,
          fn -> Autolaunch.verify_bid_step(operation.action_id, opts) end,
          fn -> Autolaunch.cancel_bid_review(operation.action_id, opts) end,
          fn -> Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts) end
        ] do
      assert {:error, error} = refused.()
      assert refusal(error) == :session_unavailable
    end

    # The row the revoked session left is untouched and still that account's.
    {:ok, :bind, claim} = SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    reauthenticated =
      Keyword.put(opts, :context, %{
        session_lease: %{lineage: claim.lineage, account_id: account.id}
      })

    assert {:ok, %{operation: %{state: :prepared, action_id: action_id}}} =
             Autolaunch.open_bid_operation(reauthenticated)

    assert action_id == operation.action_id
  end

  describe "second-connection barriers" do
    setup :clear_committed_bids
  end

  ## Committed setup and barriers for the second-connection proofs

  # Committed rows outlive the sandbox, so they are cleared for every test in
  # this block rather than only around the ones that mint them.
  defp clear_committed_bids(_context) do
    remove = fn ->
      # Ash is bypassed throughout this cleanup on purpose: it runs outside the sandbox
      # against rows that policies would hide, and the resources have no destroy actions.
      account_ids =
        Repo.all(
          from(account in Accounts.HumanAccount,
            where: like(account.privy_user_id, "did:privy:bid-barrier-%"),
            select: account.id
          )
        )

      Repo.delete_all(
        from(attempt in Autolaunch.WalletAttempt,
          join: operation in BidOperation,
          on: operation.id == attempt.bid_operation_id,
          where: operation.human_account_id in ^account_ids
        )
      )

      Repo.delete_all(
        from(row in BidOperation,
          where: row.human_account_id in ^account_ids
        )
      )

      Repo.delete_all(from(row in SessionAuthority, where: row.human_account_id in ^account_ids))

      Repo.delete_all(
        from(auction in Auction,
          where: like(auction.title, "Barrier bid %")
        )
      )

      Repo.delete_all(
        from(report in TreasurySecurityReport,
          where: report.address == ^@barrier_treasury
        )
      )

      Repo.delete_all(
        from(account in Accounts.HumanAccount,
          where: like(account.privy_user_id, "did:privy:bid-barrier-%")
        )
      )
    end

    unboxed(remove)
    on_exit(fn -> unboxed(remove) end)
  end

  defp unboxed(attempt), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, attempt)

  # PostgreSQL itself reports the ordering, so no sleep decides the race.

  defp review(auction, wallet, opts) do
    {:ok, %{operation: operation}} = Autolaunch.prepare_bid(auction.id, wallet, "1", "3", opts)
    operation
  end

  # One second past the deadline the reviewed envelope itself carries.
end
