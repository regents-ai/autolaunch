defmodule Autolaunch.LaunchActions do
  @moduledoc """
  The one boundary between a founder's wallet and the launch factory.

  Preparation reads Base once and saves the review (`Autolaunch.LaunchOperation`):
  the one `launch` step for the wallet that may act, and the facts the page
  shows. The page sends that step as it stands; nothing about a press is
  stored, and `Autolaunch.LaunchReviews` lists the launch from the chain.

  The wallet is Privy's active wallet, proved to be one of the account the
  mounted lease resolves to before any private fact is read. Provider reads
  happen before the lease transaction; only the row write happens inside it.
  """

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, LaunchAbi}
  alias RegentChain.{Address, Review}

  alias Autolaunch.{
    Lab,
    LabAbi,
    LaunchChainClient,
    LaunchDraft,
    LaunchDraftImageStorage,
    LaunchOperations,
    TreasurySecurity
  }

  # The factory's own inclusive byte caps on the five metadata strings. Each must
  # also be nonempty, which is what a historical draft can fail.
  @metadata [name: 64, symbol: 16, description: 512, website: 256]

  # Three of the exact six treasuries the strategy refuses are frozen constants
  # rather than reads: autolaunch-contracts 5cf4a6b48388d54593b83230342542fee7c0f131
  # src/bindings/BaseBindings.sol lines 19-21, refused together with the factory,
  # the strategy and its hook at src/strategy/RegentLBPStrategy.sol lines 673-679.
  @frozen_refused_treasuries [
    "0x498581fF718922c3f8e6A244956aF099B2652b2b",
    "0x7C5f5A4bBd8fD63184577525326123B519429bDc",
    "0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5"
  ]

  @withdrawn "review withdrawn"

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

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
         {:ok, fields} <- launchable(draft, actor),
         {:ok, snapshot} <- snapshot(signer),
         :ok <- reviewable(fields, snapshot),
         {:ok, treasury_report} <- review_treasury(draft),
         review <- review(draft, fields, signer, snapshot, treasury_report),
         {:ok, operation} <- open(lease, draft, signer, review) do
      {:ok, reviewed(operation)}
    end
  end

  @doc "Withdraws one saved review the page is done with."
  @spec cancel(String.t(), keyword()) :: {:ok, Ash.Resource.record()} | {:error, term()}
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
  @spec reviewed(Ash.Resource.record()) :: map()
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

  @doc "The founder-frozen terms, in the order a review presents their exact values."
  @spec terms() :: [String.t()]
  def terms, do: Enum.map(LaunchAbi.terms(), &Atom.to_string/1)

  # Reviews

  # The saved review: fixed once written, and read back exactly as stored.
  defp review(draft, fields, signer, snapshot, treasury_report) do
    config = Lab.current!()

    %{
      "chain" => Client.chain(config),
      "signer" => signer,
      "step" => Review.step("launch", snapshot.factory, launch_data(config, fields)),
      "facts" => facts(draft, fields, snapshot, treasury_report)
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp launch_data(config, fields) do
    LabAbi.encode(
      Lab.abi!(config, :factory),
      "launch((string,string,string,string,string,address,uint128))",
      [
        [
          fields.name,
          fields.symbol,
          fields.description,
          fields.website,
          fields.image,
          fields.treasury,
          fields.required_regent_raised
        ]
      ]
    )
  end

  defp facts(draft, fields, snapshot, treasury_report) do
    %{
      "draft_id" => draft.id,
      "name" => fields.name,
      "symbol" => fields.symbol,
      "description" => fields.description,
      "website" => fields.website,
      "image" => fields.image,
      "treasury" => fields.treasury,
      "treasury_security" => treasury_binding(treasury_report),
      "required_regent_raised" => LaunchDraft.onchain_required_raise(draft),
      "required_regent_raised_atomic" => Integer.to_string(fields.required_regent_raised),
      "regent" => snapshot.regent,
      "factory" => snapshot.factory,
      "strategy" => snapshot.strategy,
      "hook" => snapshot.hook,
      "block_number" => snapshot.block.number,
      "block_hash" => snapshot.block.hash,
      "terms" => Map.new(snapshot.terms, fn {id, value} -> {to_string(id), to_string(value)} end),
      "risk" => risk_copy()
    }
  end

  defp risk_copy do
    if Lab.test_chain?(),
      do:
        "Your wallet creates this launch on a Base fork with test assets and no mainnet value. There is no launch fee.",
      else:
        "Your wallet creates this launch on Base. There is no launch fee, so no REGENT moves. A launch cannot be undone."
  end

  # Stored drafts

  # The draft is read through the owner's own `mine` action, so a draft this
  # account does not hold is never even named.
  defp owned_draft(draft_id, actor) do
    case Autolaunch.get_my_launch_draft(draft_id, actor: actor) do
      {:ok, nil} -> unavailable(:launch_draft_not_found)
      {:ok, draft} -> {:ok, draft}
      {:error, _reason} -> unavailable(:launch_draft_unavailable)
    end
  end

  # Everything the factory itself requires of a saved draft. A row written before
  # the nonempty rule, or one carrying an amount this factory cannot hold, is
  # refused here rather than reverting in the customer's wallet.
  defp launchable(draft, actor) do
    with :ok <- metadata(draft),
         {:ok, image} <- launch_image(draft, actor),
         true <- LaunchDraft.treasury_complete?(draft),
         {:ok, treasury} <- address(draft.treasury, :launch_treasury_invalid),
         {:ok, atomic} <- atomic_raise(LaunchDraft.onchain_required_raise(draft)) do
      {:ok,
       %{
         name: draft.name,
         symbol: draft.symbol,
         description: draft.description,
         website: draft.website,
         image: image,
         treasury: treasury,
         required_regent_raised: atomic
       }}
    else
      false -> unavailable(:launch_treasury_invalid)
      error -> error
    end
  end

  defp launch_image(draft, actor) do
    with true <- LaunchDraft.image_complete?(draft),
         {:ok,
          %{
            id: image_id,
            launch_draft_id: image_draft_id
          } = image} <- Autolaunch.get_my_launch_draft_image(draft.id, actor: actor),
         true <- image_id == draft.launch_draft_image_id,
         true <- image_draft_id == draft.id,
         expected <- LaunchDraftImageStorage.public_url(image),
         true <- expected == draft.image do
      {:ok, expected}
    else
      _unavailable -> unavailable(:launch_metadata_incomplete)
    end
  end

  defp metadata(draft) do
    if Enum.all?(@metadata, fn {field, limit} -> within?(Map.fetch!(draft, field), limit) end),
      do: :ok,
      else: unavailable(:launch_metadata_incomplete)
  end

  defp within?(value, limit),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit

  defp atomic_raise(value) do
    case LaunchAbi.atomic_raise(value) do
      {:ok, atomic} -> {:ok, atomic}
      :error -> unavailable(:launch_raise_invalid)
    end
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  # Chain snapshot

  defp snapshot(signer) do
    case LaunchChainClient.module().snapshot(%{signer: signer}) do
      {:ok, snapshot} -> complete(snapshot)
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp accepted_regent?(%{regent: regent}),
    do: Address.equal?(regent, Abi.regent_address())

  defp accepted_regent?(_snapshot), do: false

  # A review is derived from one whole snapshot or from none, so a partial answer
  # is refused before any of it is believed.
  defp complete(snapshot) do
    with %{factory: factory, strategy: strategy, strategy_factory: bound, hook: hook} <- snapshot,
         %{paused: paused, terms: terms, block: block} <- snapshot,
         true <-
           Enum.all?([factory, strategy, bound, hook], &match?({:ok, _}, Address.normalize(&1))),
         true <- is_boolean(paused),
         true <- match?(%{number: number, hash: _} when is_integer(number), block),
         true <- Enum.sort(Map.keys(terms)) == Enum.sort(LaunchAbi.terms()),
         true <- Enum.all?(Map.values(terms), &is_integer/1) do
      {:ok, snapshot}
    else
      _partial -> unavailable(:launch_snapshot_incomplete)
    end
  end

  # Every reason a launch is refused before a durable review can exist at all.
  defp reviewable(fields, snapshot) do
    cond do
      not accepted_regent?(snapshot) ->
        unavailable(:regent_address_mismatch)

      snapshot.paused ->
        unavailable(:launches_paused)

      refused_treasury?(fields.treasury, snapshot) ->
        unavailable(:launch_treasury_refused)

      # Two separate ceilings: the reviewed strategy's own reachable maximum,
      # which is a chain-supplied value, and the structural limit of the
      # `uint128` field the tuple carries it in.
      fields.required_regent_raised > snapshot.terms.max_reachable_raise ->
        excessive()

      fields.required_regent_raised > LaunchAbi.uint128_max() ->
        excessive()

      not same?(snapshot.strategy_factory, snapshot.factory) ->
        unavailable(:strategy_not_bound)

      true ->
        :ok
    end
  end

  # The exact six the strategy refuses as a launch treasury: the factory, the
  # strategy and the hook it is bound to, all read at the reviewed block, plus the
  # three frozen Base bindings.
  defp refused_treasury?(treasury, %{factory: factory, strategy: strategy, hook: hook}),
    do: Enum.any?([factory, strategy, hook | @frozen_refused_treasuries], &same?(treasury, &1))

  defp excessive, do: unavailable(:required_raise_unreachable)

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

  defp review_treasury(draft) do
    if Lab.test_chain?() do
      {:ok,
       %{
         "mode" => "local_lab",
         "address" => draft.treasury,
         "path" => Atom.to_string(draft.treasury_path)
       }}
    else
      production_treasury(draft)
    end
  end

  defp production_treasury(draft) do
    case Autolaunch.current_treasury_security(draft.treasury, actor: nil) do
      {:ok, nil} ->
        unavailable(:treasury_report_missing)

      {:ok, report} ->
        with {:ok, report} <-
               TreasurySecurity.revalidate_bound(report, treasury_requirement(draft)),
             :ok <- custody_address_matches(draft, report),
             :ok <- custody_matches(draft, report),
             do: {:ok, report}

      _error ->
        unavailable(:treasury_report_missing)
    end
  end

  defp treasury_requirement(%{treasury_path: :safe}), do: :verified
  defp treasury_requirement(_advanced), do: :observed

  defp custody_matches(%{treasury_path: :safe}, %{classification: :supported_safe}), do: :ok
  defp custody_matches(%{treasury_path: :eoa}, %{classification: :eoa}), do: :ok

  defp custody_matches(%{treasury_path: :contract}, %{classification: classification})
       when classification in [
              :delegated_eoa,
              :unknown_contract,
              :safe_1_of_1,
              :split,
              :unsupported
            ],
       do: :ok

  defp custody_matches(_draft, _report), do: unavailable(:treasury_security_changed)

  defp custody_address_matches(%{treasury: address}, %{address: report_address}) do
    if Address.equal?(address, report_address),
      do: :ok,
      else: unavailable(:treasury_security_changed)
  end

  defp treasury_binding(%{"mode" => "local_lab"} = binding), do: binding

  defp treasury_binding(report) do
    %{
      "report_id" => report.id,
      "address" => report.address,
      "configuration_fingerprint" => report.configuration_fingerprint,
      "source_block_hash" => report.source_block_hash,
      "source_block_number" => report.source_block_number,
      "classification" => Atom.to_string(report.classification),
      "verification_state" => Atom.to_string(report.verification_state),
      "downgrade_state" => Atom.to_string(report.downgrade_state),
      "evidence" => %{
        "usdc" => report.usdc_evidence,
        "regent" => report.regent_evidence,
        "outbound" => report.outbound_evidence
      }
    }
  end

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

  # The account the mounted lease resolves to right now. A lineage that has been
  # revoked, rebound or whose provider evidence has lapsed resolves to nothing.
  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  # The lease and the acting human have to name one account, so a lease held for
  # another account answers about nothing.
  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  # Shared helpers

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  defp same?(left, right), do: Address.equal?(left, right)

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
