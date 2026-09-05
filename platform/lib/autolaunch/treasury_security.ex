defmodule Autolaunch.TreasurySecurity do
  @moduledoc """
  The one custody-classification boundary used by launch and bid reviews.

  Callers supply only an address and transaction hashes. Every persisted fact is
  derived from one canonical Base observation and is written through the
  SystemActor-only report action.
  """

  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.Chain.Address
  alias Autolaunch.Repo
  alias Autolaunch.{TreasuryChainClient, TreasurySecurityReport}

  @chain_id 8453
  @zero "0x0000000000000000000000000000000000000000"

  @spec observe(String.t(), map(), Human.t() | System.t()) ::
          {:ok, TreasurySecurityReport.t()} | {:error, term()}
  def observe(address, evidence, actor) do
    with :ok <- authorized_actor(actor),
         {:ok, address} <- Address.normalize(address),
         {:ok, evidence} <- evidence_input(evidence),
         {:ok, observation} <- TreasuryChainClient.observe(address, evidence),
         {:ok, attrs} <- report_attrs(address, observation),
         do: persist_observation(attrs)
  end

  @doc "Pins a report relationship to the same canonical immutable treasury address."
  def associate_report_address(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      associate_attribute_report(changeset)
    end)
  end

  @doc "Derives a token's custody provenance from its auction and optional subject."
  def associate_token_report(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with {:ok, auction} <- auction(Ash.Changeset.get_attribute(changeset, :auction_id)),
           {:ok, binding} <- auction_binding(auction),
           :ok <- subject_agrees(Ash.Changeset.get_attribute(changeset, :subject_id), binding) do
        bind_auction_report(changeset, binding)
      else
        {:error, message} -> provenance_error(changeset, message)
      end
    end)
  end

  @doc "Derives a launch job's custody provenance whenever it references an auction."
  def associate_launch_job_report(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :auction_id) do
        nil ->
          associate_attribute_report(changeset)

        auction_id ->
          bind_launch_job_auction_report(changeset, auction_id)
      end
    end)
  end

  @doc "A fresh report may replace the bound row only when every security fact is unchanged."
  def revalidate_bound(report, requirement \\ :verified)

  def revalidate_bound(%TreasurySecurityReport{} = bound, requirement) do
    with :ok <- bound_allowed(bound, requirement),
         true <-
           TreasuryChainClient.canonical?(bound.source_block_number, bound.source_block_hash),
         {:ok, fresh} <- observe(bound.address, evidence_hashes(bound), %System{}),
         :ok <- same_security_state(bound, fresh, requirement) do
      {:ok, fresh}
    else
      false -> {:error, :treasury_source_reorged}
      {:error, reason} -> {:error, reason}
    end
  end

  def revalidate_bound(_report, _requirement), do: {:error, :treasury_report_missing}

  def fingerprint(address, observation) do
    canonical = [
      @chain_id,
      address,
      observation.runtime_identity,
      observation.safe_singleton,
      observation.safe_version,
      Enum.sort(observation.owners),
      observation.threshold,
      Enum.sort(observation.modules),
      observation.guard,
      observation.fallback_handler
    ]

    "0x" <>
      (:crypto.hash(:sha256, Jason.encode!(canonical))
       |> Base.encode16(case: :lower))
  end

  @doc "The fail-closed public state before projector-owned canonical refresh integrates."
  def public_view(nil), do: nil

  def public_view(report) do
    %{
      id: report.id,
      address: report.address,
      chain_id: report.chain_id,
      classification: to_string(report.classification),
      verification_state: "awaiting_current_chain_confirmation",
      verification_reason: "projector_refresh_not_integrated",
      downgrade_state: to_string(report.downgrade_state),
      configuration_fingerprint: report.configuration_fingerprint,
      source_block_number: report.source_block_number,
      source_block_hash: report.source_block_hash,
      observed_at: DateTime.to_iso8601(report.observed_at),
      safe: safe_view(report),
      evidence: %{
        usdc: report.usdc_evidence,
        regent: report.regent_evidence,
        outbound: report.outbound_evidence
      }
    }
  end

  defp report_attrs(address, observation) do
    classification = classification(observation)
    fingerprint = fingerprint(address, observation)
    evidence = observation.evidence || %{}
    verified? = verified_safe?(classification, observation, evidence, fingerprint)

    {:ok,
     %{
       address: address,
       chain_id: @chain_id,
       classification: classification,
       safe_version: observation.safe_version,
       safe_singleton: observation.safe_singleton,
       owner_addresses: Enum.sort(observation.owners),
       owner_count: length(observation.owners),
       threshold: observation.threshold,
       modules: Enum.sort(observation.modules),
       guard: observation.guard,
       fallback_handler: observation.fallback_handler,
       configuration_fingerprint: fingerprint,
       source_block_number: observation.block.number,
       source_block_hash: observation.block.hash,
       observed_at: DateTime.utc_now(),
       verification_state: if(verified?, do: :verified, else: :unverified),
       verification_reason:
         verification_reason(classification, observation, evidence, fingerprint, verified?),
       usdc_evidence: evidence[:usdc],
       regent_evidence: evidence[:regent],
       outbound_evidence: evidence[:outbound],
       downgrade_state: :none,
       prior_verified_fingerprint: nil
     }}
  rescue
    _malformed -> {:error, :treasury_observation_incomplete}
  end

  # Classification precedence is deliberate: empty code, then exact EIP-7702,
  # then admitted bytecode. Interface resemblance never enters this function.
  defp classification(%{runtime_code: "0x"}), do: :eoa

  defp classification(%{runtime_code: "0xef0100" <> delegate})
       when byte_size(delegate) == 40,
       do: :delegated_eoa

  defp classification(%{admitted_safe?: true, owners: [_], threshold: 1}), do: :safe_1_of_1
  defp classification(%{admitted_safe?: true}), do: :supported_safe
  defp classification(%{admitted_split?: true}), do: :split
  defp classification(%{runtime_code: "0x" <> _}), do: :unknown_contract
  defp classification(_observation), do: :unsupported

  defp verified_safe?(:supported_safe, observation, evidence, fingerprint) do
    exactly_three?(observation.owners) and
      observation.owners == Enum.uniq(observation.owners) and
      observation.threshold == 2 and observation.modules == [] and
      observation.guard == @zero and observation.fallback_admitted? and
      evidence_verified?(evidence_value(evidence, :usdc), fingerprint) and
      evidence_verified?(evidence_value(evidence, :regent), fingerprint) and
      evidence_verified?(evidence_value(evidence, :outbound), fingerprint)
  end

  defp verified_safe?(_classification, _observation, _evidence, _fingerprint), do: false

  defp evidence_verified?(%{verified: true, historical_fingerprint: fingerprint}, fingerprint),
    do: true

  defp evidence_verified?(
         %{"verified" => true, "historical_fingerprint" => fingerprint},
         fingerprint
       ),
       do: true

  defp evidence_verified?(_evidence, _fingerprint), do: false

  defp verification_reason(_class, _observation, _evidence, _fingerprint, true), do: "verified"

  defp verification_reason(:eoa, _observation, _evidence, _fingerprint, false),
    do: "single_key_eoa"

  defp verification_reason(:delegated_eoa, _observation, _evidence, _fingerprint, false),
    do: "delegated_eoa"

  defp verification_reason(:safe_1_of_1, _observation, _evidence, _fingerprint, false),
    do: "safe_1_of_1"

  defp verification_reason(:unknown_contract, _observation, _evidence, _fingerprint, false),
    do: "unknown_contract"

  defp verification_reason(:split, _observation, _evidence, _fingerprint, false),
    do: "unverified_split"

  defp verification_reason(:unsupported, _observation, _evidence, _fingerprint, false),
    do: "unsupported"

  defp verification_reason(:supported_safe, observation, evidence, fingerprint, false) do
    with :ok <- owners_reason(observation.owners),
         :ok <- safe_configuration_reason(observation),
         :ok <- evidence_reason(evidence, fingerprint) do
      "outbound_evidence_missing"
    else
      {:reason, reason} -> reason
    end
  end

  defp exactly_three?([_, _, _]), do: true
  defp exactly_three?(_owners), do: false

  defp owners_reason(owners) do
    cond do
      not exactly_three?(owners) -> {:reason, "safe_owner_count"}
      owners != Enum.uniq(owners) -> {:reason, "safe_duplicate_owners"}
      true -> :ok
    end
  end

  defp safe_configuration_reason(observation) do
    cond do
      observation.threshold != 2 -> {:reason, "safe_threshold"}
      observation.modules != [] -> {:reason, "safe_modules_enabled"}
      observation.guard != @zero -> {:reason, "safe_guard_enabled"}
      not observation.fallback_admitted? -> {:reason, "safe_fallback_unadmitted"}
      true -> :ok
    end
  end

  defp evidence_reason(evidence, fingerprint) do
    cond do
      not evidence_verified?(evidence_value(evidence, :usdc), fingerprint) ->
        {:reason, "usdc_evidence_missing"}

      not evidence_verified?(evidence_value(evidence, :regent), fingerprint) ->
        {:reason, "regent_evidence_missing"}

      true ->
        :ok
    end
  end

  defp evidence_value(evidence, key), do: evidence[key] || evidence[to_string(key)]

  defp persist_observation(attrs) do
    Repo.transaction(fn ->
      with :ok <- lock_address(attrs.address),
           {:ok, reports} <-
             Autolaunch.list_treasury_security_reports(attrs.address, actor: nil) do
        attrs
        |> apply_downgrade(reports)
        |> then(&persist_or_return(reports, &1))
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_address(address) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, address)

    case Repo.query("SELECT pg_advisory_xact_lock($1::bigint)", [key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_or_return(reports, attrs) do
    case Enum.find(reports, &same_observation?(&1, attrs)) do
      nil ->
        TreasurySecurityReport
        |> Ash.Changeset.for_create(:record_observation, attrs,
          domain: Autolaunch,
          actor: %System{}
        )
        |> Ash.create(domain: Autolaunch, actor: %System{})

      report ->
        {:ok, report}
    end
  end

  defp same_observation?(report, attrs) do
    report.source_block_hash == attrs.source_block_hash and
      report.configuration_fingerprint == attrs.configuration_fingerprint and
      report.verification_state == attrs.verification_state and
      report.verification_reason == attrs.verification_reason and
      report.downgrade_state == attrs.downgrade_state and
      evidence_hash(report.usdc_evidence) == evidence_hash(attrs.usdc_evidence) and
      evidence_hash(report.regent_evidence) == evidence_hash(attrs.regent_evidence) and
      evidence_hash(report.outbound_evidence) == evidence_hash(attrs.outbound_evidence)
  end

  defp apply_downgrade(attrs, reports) do
    case downgrade_origin(attrs, reports) do
      nil ->
        attrs

      prior_verified_fingerprint ->
        %{
          attrs
          | downgrade_state: :downgraded,
            prior_verified_fingerprint: prior_verified_fingerprint,
            verification_state: :unverified,
            verification_reason: "configuration_changed"
        }
    end
  end

  defp downgrade_origin(attrs, reports) do
    sticky_origin(reports) || verified_divergence(attrs, reports) ||
      restored_divergence(attrs, reports)
  end

  defp sticky_origin(reports) do
    downgraded = Enum.filter(reports, &(&1.downgrade_state == :downgraded))

    first_fingerprint(downgraded, & &1.prior_verified_fingerprint) ||
      first_fingerprint(downgraded, & &1.configuration_fingerprint)
  end

  defp verified_divergence(attrs, reports) do
    reports
    |> Enum.filter(
      &(&1.verification_state == :verified and
          &1.configuration_fingerprint != attrs.configuration_fingerprint)
    )
    |> first_fingerprint(& &1.configuration_fingerprint)
  end

  defp restored_divergence(%{verification_state: :verified} = attrs, reports) do
    if Enum.any?(reports, &(&1.configuration_fingerprint != attrs.configuration_fingerprint)),
      do: attrs.configuration_fingerprint
  end

  defp restored_divergence(_attrs, _reports), do: nil

  defp first_fingerprint(reports, field) do
    reports
    |> Enum.map(field)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
  end

  defp evidence_input(evidence) when is_map(evidence) do
    keys = [:usdc, :regent, :outbound]

    evidence =
      Map.new(keys, &{&1, normalize_evidence_hash(evidence[&1] || evidence[to_string(&1)])})

    if Enum.all?(keys, &valid_optional_hash?(evidence[&1])) and distinct_hashes?(evidence) do
      {:ok, evidence}
    else
      {:error, :treasury_evidence_hash_invalid}
    end
  end

  defp evidence_input(_evidence), do: {:error, :treasury_evidence_hash_invalid}

  defp associate_attribute_report(changeset) do
    report_id = Ash.Changeset.get_attribute(changeset, :treasury_security_report_id)
    treasury_address = Ash.Changeset.get_attribute(changeset, :treasury_address)

    case report_id && Autolaunch.get_treasury_security_report(report_id, actor: nil) do
      nil ->
        changeset

      {:ok, %{address: report_address}} ->
        associate_report_address(changeset, treasury_address, report_address)

      _missing ->
        provenance_error(changeset, "does not identify a treasury security report")
    end
  end

  defp auction(id) do
    case Autolaunch.get_public_auction(id, actor: nil) do
      {:ok, nil} -> {:error, "requires an existing auction"}
      {:ok, auction} -> {:ok, auction}
      _error -> {:error, "requires an existing auction"}
    end
  end

  defp auction_binding(%{
         treasury_security_report_id: report_id,
         treasury_address: address,
         treasury_security_report: report
       }) do
    case {report_id, address, report} do
      {nil, nil, nil} -> {:ok, %{report_id: nil, address: nil}}
      {id, address, %{id: id, address: address}} -> {:ok, %{report_id: id, address: address}}
      _mismatch -> {:error, "auction custody provenance is inconsistent"}
    end
  end

  defp bind_launch_job_auction_report(changeset, auction_id) do
    with {:ok, auction} <- auction(auction_id),
         {:ok, binding} <- auction_binding(auction) do
      bind_auction_report(changeset, binding)
    else
      {:error, message} -> provenance_error(changeset, message)
    end
  end

  defp subject_agrees(nil, _binding), do: :ok

  defp subject_agrees(subject_id, binding) do
    case Autolaunch.get_public_subject(subject_id, actor: nil) do
      {:ok, %{treasury_security_report_id: nil, treasury_address: subject_address}} ->
        case {Address.normalize(subject_address), Address.normalize(binding.address)} do
          {{:ok, address}, {:ok, address}} -> :ok
          _mismatch -> {:error, "subject custody provenance must match its auction"}
        end

      {:ok,
       %{
         treasury_security_report_id: report_id,
         treasury_address: address,
         treasury_security_report: report
       }} ->
        case {report_id, address, report, binding} do
          {id, address, %{id: id, address: address}, %{report_id: id, address: address}} -> :ok
          _mismatch -> {:error, "subject custody provenance must match its auction"}
        end

      _missing ->
        {:error, "requires an existing subject"}
    end
  end

  defp bind_auction_report(changeset, binding) do
    supplied = Ash.Changeset.get_attribute(changeset, :treasury_security_report_id)

    if is_nil(supplied) or supplied == binding.report_id do
      changeset
      |> Ash.Changeset.force_change_attribute(:treasury_security_report_id, binding.report_id)
      |> Ash.Changeset.force_change_attribute(:treasury_address, binding.address)
    else
      provenance_error(changeset, "must match the referenced auction")
    end
  end

  defp provenance_error(changeset, message) do
    Ash.Changeset.add_error(changeset,
      field: :treasury_security_report_id,
      message: message
    )
  end

  defp associate_report_address(changeset, nil, report_address),
    do: Ash.Changeset.force_change_attribute(changeset, :treasury_address, report_address)

  defp associate_report_address(changeset, treasury_address, report_address) do
    case Address.normalize(treasury_address) do
      {:ok, ^report_address} ->
        Ash.Changeset.force_change_attribute(changeset, :treasury_address, report_address)

      _mismatch ->
        Ash.Changeset.add_error(changeset,
          field: :treasury_security_report_id,
          message: "must describe the immutable treasury address"
        )
    end
  end

  defp valid_optional_hash?(nil), do: true
  defp valid_optional_hash?(hash), do: Autolaunch.Chain.Rpc.valid_hash?(hash)

  defp distinct_hashes?(evidence) do
    hashes = evidence |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.map(&String.downcase/1)
    length(hashes) == length(Enum.uniq(hashes))
  end

  defp normalize_evidence_hash(""), do: nil
  defp normalize_evidence_hash(hash), do: hash

  defp authorized_actor(%Human{}), do: :ok
  defp authorized_actor(%System{}), do: :ok
  defp authorized_actor(_actor), do: {:error, :authentication_required}

  defp bound_allowed(%{verification_state: :verified, downgrade_state: :none}, :verified), do: :ok
  defp bound_allowed(%{downgrade_state: :none}, :observed), do: :ok
  defp bound_allowed(_report, :verified), do: {:error, :treasury_not_verified}
  defp bound_allowed(_report, :observed), do: {:error, :treasury_security_changed}
  defp bound_allowed(_report, _requirement), do: {:error, :treasury_requirement_invalid}

  defp same_security_state(bound, fresh, requirement) do
    verified? = requirement == :observed or fresh.verification_state == :verified

    if verified? and fresh.downgrade_state == bound.downgrade_state and
         fresh.classification == bound.classification and
         fresh.configuration_fingerprint == bound.configuration_fingerprint do
      :ok
    else
      {:error, :treasury_security_changed}
    end
  end

  defp evidence_hashes(report) do
    %{
      usdc: evidence_hash(report.usdc_evidence),
      regent: evidence_hash(report.regent_evidence),
      outbound: evidence_hash(report.outbound_evidence)
    }
  end

  defp evidence_hash(%{"transaction_hash" => hash}), do: hash
  defp evidence_hash(%{transaction_hash: hash}), do: hash
  defp evidence_hash(_evidence), do: nil

  defp safe_view(%{safe_singleton: nil}), do: nil

  defp safe_view(report) do
    %{
      version: report.safe_version,
      singleton: report.safe_singleton,
      owners: report.owner_addresses,
      owner_count: report.owner_count,
      threshold: report.threshold,
      modules: report.modules,
      guard: report.guard,
      fallback_handler: report.fallback_handler
    }
  end
end
