defmodule Autolaunch.SubjectWalletOperationTest do
  @moduledoc """
  The durable operation itself: the identities the database enforces, the
  transitions it will and will not make, and the authority it demands.
  """

  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.SubjectWalletOperation

  @wallet "0x1111111111111111111111111111111111111111"
  @subject "subject:operation"
  @other_subject "subject:operation:other"
  @hash "0x" <> String.duplicate("ab", 32)
  @other_hash "0x" <> String.duplicate("cd", 32)

  setup do
    {:ok, account: account!()}
  end

  describe "IDENTITY_DECIDES_EVERY_RACE" do
    test "an action id is unique across every operation, even on another subject", %{
      account: account
    } do
      assert {:ok, first} = prepare(account, action_id: "a")

      # A different subject clears the one-open-per-subject slot, so the only
      # identity left to refuse this is the action id itself.
      assert {:error, error} =
               prepare(account, action_id: first.action_id, subject_id: @other_subject)

      assert conflict?(error, :action_id)
    end

    test "one open operation exists per account and subject, and a different subject is free", %{
      account: account
    } do
      assert {:ok, _open} = prepare(account, action_id: "a")
      assert {:error, error} = prepare(account, action_id: "b")
      assert conflict?(error, :human_account_id)

      # A different subject is completely independent.
      assert {:ok, _other} = prepare(account, action_id: "c", subject_id: @other_subject)

      # And a different account may open one on the same subject.
      assert {:ok, _theirs} = prepare(account!(), action_id: "d")
    end

    test "a terminal operation releases the slot without releasing its hashes", %{
      account: account
    } do
      {:ok, operation} = submitted(account, "a")
      {:ok, _closed} = update(operation, :close_submission_unknown, %{reason: "unresolved"})

      assert {:ok, next} = prepare(account, action_id: "b")
      {:ok, next} = update(next, :claim_dispatch)

      # The slot is free; the hash the first operation bound is not.
      assert {:error, error} = update(next, :bind_hash, %{action_transaction_hash: @hash})
      assert conflict?(error, :action_transaction_hash)
    end

    test "each phase's hash column is unique on its own", %{account: account} do
      {:ok, first} = prepare(account, action_id: "a", step: :approval)
      {:ok, first} = update(first, :claim_dispatch)
      {:ok, _bound} = update(first, :bind_hash, %{approval_transaction_hash: @hash})

      # The same hash cannot be an approval hash twice.
      {:ok, _closed} = reload(first) |> update(:close_submission_unknown, %{reason: "unresolved"})
      {:ok, second} = prepare(account, action_id: "b", step: :approval)
      {:ok, second} = update(second, :claim_dispatch)

      assert {:error, error} = update(second, :bind_hash, %{approval_transaction_hash: @hash})
      assert conflict?(error, :approval_transaction_hash)

      # A different hash in the same column is accepted.
      assert {:ok, _other} = update(second, :bind_hash, %{approval_transaction_hash: @other_hash})
    end
  end

  describe "EXACTLY_ONE_SENDABLE_STEP" do
    test "a dispatch is claimable only from prepared", %{account: account} do
      {:ok, operation} = prepare(account, action_id: "a")
      {:ok, dispatched} = update(operation, :claim_dispatch)

      assert {:error, _refused} = update(dispatched, :claim_dispatch)
    end

    test "a hash binds only from dispatched, and only once", %{account: account} do
      {:ok, operation} = prepare(account, action_id: "a")

      assert {:error, _too_early} =
               update(operation, :bind_hash, %{action_transaction_hash: @hash})

      {:ok, dispatched} = update(operation, :claim_dispatch)
      {:ok, submitted} = update(dispatched, :bind_hash, %{action_transaction_hash: @hash})
      assert submitted.state == :submitted

      assert {:error, _already_bound} =
               update(submitted, :bind_hash, %{action_transaction_hash: @other_hash})
    end

    test "an approval advances to the action, and an action confirms terminally", %{
      account: account
    } do
      {:ok, operation} = prepare(account, action_id: "a", step: :approval)
      {:ok, operation} = update(operation, :claim_dispatch)
      {:ok, operation} = update(operation, :bind_hash, %{approval_transaction_hash: @hash})
      {:ok, advanced} = update(operation, :advance)

      assert advanced.step == :action
      assert advanced.state == :prepared
      assert advanced.approval_transaction_hash == @hash
      assert is_nil(advanced.terminal_at)

      {:ok, advanced} = update(advanced, :claim_dispatch)
      {:ok, advanced} = update(advanced, :bind_hash, %{action_transaction_hash: @other_hash})
      {:ok, confirmed} = update(advanced, :confirm, %{result: %{"claimed" => %{}}})

      assert confirmed.state == :confirmed
      assert confirmed.terminal_at
    end

    test "the action phase never advances, so nothing follows a confirmed action", %{
      account: account
    } do
      {:ok, operation} = submitted(account, "a")

      assert {:error, _refused} = update(operation, :advance)
    end
  end

  describe "TERMINAL_STAYS_TERMINAL" do
    test "no terminal operation accepts another lifecycle transition", %{account: account} do
      {:ok, operation} = submitted(account, "a")
      {:ok, reverted} = update(operation, :record_revert, %{reason: "verified revert on Base"})

      for action <- [:claim_dispatch, :advance, :confirm, :record_unverified, :cancel] do
        assert {:error, _refused} = update(reverted, action, %{})
      end
    end

    test "a late hash attaches to a terminal operation without reopening it", %{account: account} do
      {:ok, operation} = prepare(account, action_id: "a")
      {:ok, operation} = update(operation, :claim_dispatch)
      {:ok, closed} = update(operation, :close_not_sent, %{reason: "rejected"})

      assert {:ok, attached} =
               update(closed, :attach_late_hash, %{action_transaction_hash: @hash})

      assert attached.action_transaction_hash == @hash
      assert attached.state == :not_sent
      assert attached.terminal_at == closed.terminal_at
    end

    test "a late hash cannot be attached to an operation that is still open", %{account: account} do
      {:ok, operation} = prepare(account, action_id: "a")

      assert {:error, _refused} =
               update(operation, :attach_late_hash, %{action_transaction_hash: @hash})
    end
  end

  describe "SYSTEM_ACTOR_ONLY: no browser actor reaches this row" do
    test "a human actor can neither read nor write an operation", %{account: account} do
      {:ok, operation} = prepare(account, action_id: "a")
      human = %Human{human_account_id: account.id}

      assert {:error, _forbidden} =
               SubjectWalletOperation |> Ash.Query.new() |> Ash.read(actor: human)

      assert {:error, _forbidden} =
               operation
               |> Ash.Changeset.for_update(:claim_dispatch, %{}, actor: human)
               |> Ash.update(actor: human)
    end

    test "an anonymous actor is refused outright", %{account: account} do
      {:ok, _operation} = prepare(account, action_id: "a")

      assert {:error, _forbidden} =
               SubjectWalletOperation |> Ash.Query.new() |> Ash.read(actor: nil)
    end
  end

  # Helpers

  defp account! do
    Accounts.register_verified!(
      "did:privy:subject-operation:#{Elixir.System.unique_integer([:positive])}",
      @wallet,
      [@wallet],
      actor: %System{}
    )
  end

  defp prepare(account, options) do
    SubjectWalletOperation
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        action_id: String.pad_leading(Keyword.fetch!(options, :action_id), 64, "0"),
        subject_id: Keyword.get(options, :subject_id, @subject),
        kind: Keyword.get(options, :kind, :unstake),
        envelope: %{"arguments" => %{}},
        signer: @wallet,
        step: Keyword.get(options, :step, :action),
        human_account_id: account.id
      },
      actor: %System{}
    )
    |> Ash.create(actor: %System{})
  end

  defp submitted(account, action_id) do
    {:ok, operation} = prepare(account, action_id: action_id)
    {:ok, operation} = update(operation, :claim_dispatch)
    update(operation, :bind_hash, %{action_transaction_hash: @hash})
  end

  defp update(operation, action, input \\ %{}) do
    operation
    |> Ash.Changeset.for_update(action, input, actor: %System{})
    |> Ash.update(actor: %System{})
  end

  defp reload(operation), do: Ash.get!(SubjectWalletOperation, operation.id, actor: %System{})

  # The database refused this write on the identity that protects the invariant,
  # rather than on some incidental validation.
  defp conflict?(error, field) do
    error
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Ash.Error.Changes.InvalidAttribute{field: ^field}, &1))
  end
end
