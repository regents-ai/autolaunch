defmodule Autolaunch do
  use Ash.Domain,
    otp_app: :autolaunch

  require Ash.Query

  @payment_link_resource Module.concat(__MODULE__, "PaymentLink")
  @launch_draft_image_resource Module.concat(__MODULE__, "LaunchDraftImage")
  @bid_operation Module.concat(__MODULE__, "BidOperation")
  @subject_wallet_operation Module.concat(__MODULE__, "SubjectWalletOperation")
  @launch_operation Module.concat(__MODULE__, "LaunchOperation")
  resources do
    resource Autolaunch.LaunchDraft do
      define :create_launch_draft, action: :create_for_owner
      define :list_my_launch_drafts, action: :mine

      define :get_my_account_launch_draft,
        action: :mine_account_owned,
        not_found_error?: false

      define :get_my_launch_draft,
        action: :mine_by_id,
        args: [:id],
        not_found_error?: false

      define :get_my_launch_draft_for_update,
        action: :mine_by_id_for_update,
        args: [:id],
        not_found_error?: false

      define :autosave_launch_token_details, action: :autosave_token_details
      define :autosave_launch_treasury, action: :autosave_treasury

      define :attach_launch_draft_image,
        action: :attach_image,
        args: [:launch_draft_image_id]

      define :revise_account_launch_draft, action: :revise_by_owner
    end

    # Keep this registration dynamic like the operation-only resources below;
    # its interfaces remain explicit without widening the domain compile graph.
    resource @launch_draft_image_resource do
      define :create_launch_draft_image,
        action: :store_for_owner,
        args: [:bytes, :content_type, :original_filename, :launch_draft_id]

      define :get_my_launch_draft_image,
        action: :mine,
        args: [:launch_draft_id],
        not_found_error?: false

      define :get_my_launch_draft_image_for_reuse,
        action: :mine_for_reuse,
        args: [:launch_draft_id],
        not_found_error?: false

      define :get_public_launch_draft_image,
        action: :public_by_id_and_digest,
        args: [:id, :digest],
        not_found_error?: false
    end

    resource Autolaunch.Auction do
      define :list_auctions, action: :list_public
      define :page_public_auctions, action: :page_public, args: [:mode, :sort]
      define :list_recent_auctions, action: :recent_public
      define :list_featured_auctions, action: :featured_public

      define :list_active_launchpad_auctions,
        action: :active_launchpad,
        args: [:query]

      define :list_explore_launchpad_auctions,
        action: :explore_launchpad,
        args: [:query]

      define :get_public_auction,
        action: :public_by_id,
        args: [:id],
        not_found_error?: false

      define :project_lab_auction, action: :project_lab
      define :project_launch_auction, action: :project_launch

      define :set_auction_bid_terms,
        action: :set_bid_terms,
        args: [
          :auction_address,
          :quote_token_address,
          :quote_token_symbol,
          :quote_token_decimals,
          :current_clearing_price
        ]

      define :set_auction_treasury_security_report,
        action: :set_treasury_security_report,
        args: [:treasury_security_report_id]

      define :list_lab_market_auctions, action: :watchable_lab

      define :get_lab_market_auction_for_update,
        action: :lab_by_id_for_update,
        args: [:id],
        not_found_error?: false

      define :refresh_lab_market_auction,
        action: :refresh_lab_market,
        args: [:state, :current_clearing_price]

      define :bid_position, action: :bid_position, args: [:auction_id, :expected_signer]

      define :prepare_bid,
        action: :prepare_bid,
        args: [:auction_id, :expected_signer, :amount, :max_price]

      define :claim_bid_dispatch, action: :claim_bid_dispatch, args: [:action_id]
      define :bind_bid_hash, action: :bind_bid_hash, args: [:action_id, :step, :transaction_hash]
      define :verify_bid_step, action: :verify_bid_step, args: [:action_id]
      define :cancel_bid_review, action: :cancel_bid_review, args: [:action_id]
      define :close_bid_not_sent, action: :close_bid_not_sent, args: [:action_id]

      define :release_unstarted_bid_dispatch,
        action: :release_unstarted_bid_dispatch,
        args: [:action_id]

      define :start_new_bid, action: :start_new_bid, args: [:action_id]
      define :open_bid_operation, action: :open_bid_operation
    end

    # The durable bidder operation is written only by `BidActions` under a
    # session lease, so it is registered without a code interface of any kind.
    resource @bid_operation

    # The durable subject wallet operation is written only by
    # `SubjectWalletOperations` under a session lease, on the same terms.
    resource @subject_wallet_operation

    # Writes stay on LaunchActions; this read is the production projection's match.
    resource @launch_operation do
      define :chain_verified_launch_operation_by_hash,
        action: :chain_verified_by_launch_hash,
        args: [:launch_transaction_hash],
        not_found_error?: false
    end

    resource Autolaunch.Token do
      define :list_tokens, action: :list_public
      define :page_public_tokens, action: :page_public
      define :list_top_tokens, action: :top_public
      define :list_recently_graduated_tokens, action: :recently_graduated_public

      define :list_graduated_launchpad_tokens,
        action: :graduated_launchpad,
        args: [:query]

      define :list_explore_launchpad_tokens,
        action: :explore_launchpad,
        args: [:query]

      define :get_public_token,
        action: :public_by_id,
        args: [:id],
        not_found_error?: false

      define :project_lab_token, action: :project_lab

      define :list_subject_tokens,
        action: :for_subject,
        args: [:subject_id]

      define :get_latest_subject_token_price,
        action: :latest_price_for_subject,
        args: [:subject_id],
        not_found_error?: false

      define :set_subject_token_price,
        action: :set_price_snapshot,
        args: [:price_quote, :price_source, :price_updated_at]
    end

    resource Autolaunch.Subject do
      define :list_subjects, action: :list_public

      define :get_public_subject,
        action: :public_by_id,
        args: [:subject_id],
        not_found_error?: false

      define :project_lab_subject, action: :project_lab

      # Only 490.8.2/.3 projection and the deterministic browser fixture write
      # the canonical receiver, so it is a named SystemActor-only setter rather
      # than another positional import argument.
      define :set_subject_canonical_receiver,
        action: :set_canonical_receiver,
        args: [:canonical_receiver_address]
    end

    resource @payment_link_resource

    resource Autolaunch.SubjectAction do
      define :list_subject_actions,
        action: :recent_for_subject,
        args: [:subject_identity]

      define :list_subject_settlements,
        action: :settlements_for_subject,
        args: [:subject_identity]
    end

    resource Autolaunch.LaunchJob do
      define :list_launches, action: :list_public

      define :get_public_launch,
        action: :public_by_id,
        args: [:job_id],
        not_found_error?: false

      define :project_lab_launch, action: :project_lab
    end

    resource Autolaunch.Bid do
      define :list_my_bid_positions, action: :mine
      define :list_my_returnable_bid_positions, action: :returnable_mine
      define :list_my_claimed_token_positions, action: :claimed_mine
      define :get_my_bid_position, action: :owned_by_bid_id, args: [:bid_id]

      define :import_bid_position,
        action: :import_position,
        args: [
          :bid_id,
          :auction_id,
          :owner_address,
          :amount,
          :max_price,
          :current_clearing_price,
          :estimated_tokens_if_end_now,
          :status,
          :exited_at,
          :claimed_at
        ]

      define :set_bid_chain_identity,
        action: :set_chain_identity,
        args: [:auction_address, :onchain_bid_id]
    end

    # The Base log ledger is written only by its own SystemActor actions, so it
    # is registered without a code interface of any kind. Plain module names:
    # Module.concat fails Spark verify (part A).
    resource Autolaunch.Indexer.Source
    resource Autolaunch.Indexer.Cursor
    resource Autolaunch.Indexer.Block
    resource Autolaunch.Indexer.Log

    resource Autolaunch.TreasurySecurityReport do
      define :list_treasury_security_reports, action: :for_address, args: [:address]

      define :get_treasury_security_report,
        action: :by_id,
        args: [:id],
        not_found_error?: false
    end
  end

  @doc "Observes Base and persists one immutable treasury security report."
  def observe_treasury_security(address, evidence, opts \\ []) do
    Autolaunch.TreasurySecurity.observe(address, evidence, Keyword.get(opts, :actor))
  end

  @doc "Returns the newest stored observation without triggering provider work."
  def current_treasury_security(address, opts \\ []) do
    with {:ok, address} <- Autolaunch.Chain.Address.normalize(address),
         {:ok, reports} <- list_treasury_security_reports(address, opts) do
      {:ok, List.first(reports)}
    end
  end

  def quote_auction_bid(auction_id, amount, max_price, opts \\ []),
    do: Autolaunch.BidActions.quote(auction_id, amount, max_price, opts)

  # The two bidder rules a presenter needs, owned here so the page and the named
  # preparation action can only ever answer the same way.
  defdelegate parse_bid_amount(value), to: Autolaunch.BidActions, as: :atomic_amount
  defdelegate bid_amount_units(amount), to: Autolaunch.BidActions, as: :units

  # The clean-V1 subject wallet lane. `SubjectWalletActions` proves the active
  # Privy wallet against the account the mounted lease locks before anything
  # private is read or anything durable moves, so these stay thin pass-throughs
  # and the resource itself keeps no code interface.
  defdelegate subject_wallet_state(subject_id, address, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :wallet_state

  defdelegate prepare_subject_wallet_action(subject_id, address, kind, params, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :prepare

  defdelegate claim_subject_wallet_dispatch(subject_id, action_id, address, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :claim_dispatch

  defdelegate bind_subject_wallet_hash(subject_id, action_id, step, hash, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :bind_hash

  defdelegate verify_subject_wallet_step(subject_id, action_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :verify

  defdelegate cancel_subject_wallet_review(subject_id, action_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :cancel

  defdelegate close_subject_wallet_not_sent(subject_id, action_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :close_not_sent

  defdelegate release_unstarted_subject_wallet_dispatch(subject_id, action_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :release_unstarted

  defdelegate start_new_subject_wallet_action(subject_id, action_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :start_new

  defdelegate open_subject_wallet_operation(subject_id, opts),
    to: Autolaunch.SubjectWalletActions,
    as: :open_operation

  # The C4 direct-wallet launch lane. `LaunchActions` proves the active Privy
  # wallet against the account the mounted lease locks before anything private is
  # read or anything durable moves, so these stay thin pass-throughs and the
  # resource itself keeps no code interface.
  defdelegate launch_wallet_state(address, opts),
    to: Autolaunch.LaunchActions,
    as: :wallet_state

  defdelegate prepare_launch(draft_id, address, opts),
    to: Autolaunch.LaunchActions,
    as: :prepare

  defdelegate claim_launch_dispatch(action_id, address, opts),
    to: Autolaunch.LaunchActions,
    as: :claim_dispatch

  defdelegate bind_launch_hash(action_id, step, hash, opts),
    to: Autolaunch.LaunchActions,
    as: :bind_hash

  defdelegate verify_launch_step(action_id, opts),
    to: Autolaunch.LaunchActions,
    as: :verify

  defdelegate cancel_launch_review(action_id, opts),
    to: Autolaunch.LaunchActions,
    as: :cancel

  defdelegate close_launch_not_sent(action_id, opts),
    to: Autolaunch.LaunchActions,
    as: :close_not_sent

  defdelegate release_unstarted_launch_dispatch(action_id, opts),
    to: Autolaunch.LaunchActions,
    as: :release_unstarted

  defdelegate start_new_launch(action_id, opts),
    to: Autolaunch.LaunchActions,
    as: :start_new

  defdelegate open_launch_operation(opts),
    to: Autolaunch.LaunchActions,
    as: :open_operation

  # Two Ash.count/read queries under the system actor: LaunchOperation is
  # system-only, and the in-flight window is "chain_verified with no Auction
  # row yet". Lab projection names that address on result["auction"].
  @spec auctions_prepared_by(integer()) :: non_neg_integer()
  def auctions_prepared_by(human_account_id) when is_integer(human_account_id) do
    actor = %Autolaunch.Actors.System{}

    auction_count =
      Autolaunch.Auction
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(creator_human_account_id == ^human_account_id)
      |> Ash.count!()

    {:ok, operations} =
      @launch_operation
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(human_account_id == ^human_account_id and state == :chain_verified)
      |> Ash.read()

    auction_count + in_flight_count(operations, actor)
  end

  defp in_flight_count(operations, actor) do
    addresses =
      operations
      |> Enum.map(&result_auction_address/1)
      |> Enum.reject(&is_nil/1)

    projected = projected_auction_addresses(addresses, actor)

    Enum.count(addresses, fn address ->
      not MapSet.member?(projected, String.downcase(address))
    end)
  end

  defp result_auction_address(%{result: result}) when is_map(result) do
    case result["auction"] do
      address when is_binary(address) and address != "" -> address
      _ -> nil
    end
  end

  defp result_auction_address(_operation), do: nil

  defp projected_auction_addresses([], _actor), do: MapSet.new()

  defp projected_auction_addresses(addresses, actor) do
    lowered = Enum.map(addresses, &String.downcase/1)

    Autolaunch.Auction
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(fragment("lower(?)", auction_address) in ^lowered)
    |> Ash.read!()
    |> MapSet.new(&String.downcase(&1.auction_address))
  end

  def list_public_auctions(mode, sort, limit, opts \\ []) do
    Autolaunch.Auction
    |> Ash.Query.for_read(:read)
    |> filter_public_auctions(mode)
    |> sort_public_auctions(sort)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:treasury_security_report)
    |> Ash.read(opts)
  end

  def list_public_tokens(limit, opts \\ []) do
    Autolaunch.Token
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(graduated_at: :desc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:treasury_security_report)
    |> Ash.read(opts)
  end

  defp filter_public_auctions(query, mode) when mode in ["biddable", "live"],
    do: Ash.Query.filter(query, state: :active)

  defp filter_public_auctions(query, "failed_minimum"),
    do: Ash.Query.filter(query, state: :failed)

  defp filter_public_auctions(query, "graduated"),
    do: Ash.Query.filter(query, state: :graduated)

  defp filter_public_auctions(query, "all"), do: query

  defp sort_public_auctions(query, "oldest") do
    Ash.Query.sort(query, opened_at: :asc, inserted_at: :asc, id: :asc)
  end

  defp sort_public_auctions(query, "newest") do
    Ash.Query.sort(query, opened_at: :desc_nils_last, inserted_at: :desc, id: :asc)
  end
end
