defmodule Autolaunch.Prelaunch do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Evm
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.Launch
  alias Autolaunch.Prelaunch.Asset
  alias Autolaunch.Prelaunch.AssetStorage
  alias Autolaunch.Prelaunch.Plan
  alias Autolaunch.Repo

  @draft_states ~w(draft validated launchable)
  @allowed_media_types ~w(image/png image/jpeg image/webp image/gif)

  def list_plans(current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor) do
      {:ok,
       Plan
       |> where([plan], plan.privy_user_id == ^owner_id)
       |> order_by([plan], desc: plan.updated_at)
       |> Repo.all()
       |> Enum.map(&serialize_plan/1)}
    end
  end

  def create_plan(attrs, current_actor) do
    with {:ok, agent_id} <- required_text(Map.get(attrs, "agent_id"), 255),
         {:ok, owner_id} <- owner_id_for(current_actor),
         %{} = agent <- Launch.get_agent(current_actor, agent_id),
         attrs <- normalize_plan_attrs(attrs, agent),
         {:ok, plan} <-
           insert_plan_with_archived_drafts(agent_id, attrs, agent, owner_id) do
      {:ok, serialize_plan(plan)}
    else
      nil -> {:error, :agent_not_found}
      {:error, _} = error -> error
    end
  end

  defp insert_plan_with_archived_drafts(agent_id, attrs, agent, owner_id) do
    now = DateTime.utc_now()

    plan_changeset =
      %Plan{}
      |> Plan.create_changeset(
        Map.merge(attrs, %{
          plan_id: "plan_" <> Ecto.UUID.generate(),
          privy_user_id: owner_id,
          chain_id: launch_chain_id(),
          identity_snapshot: identity_snapshot(agent),
          metadata_draft: metadata_draft(Map.get(attrs, "metadata_draft"))
        })
      )

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :archive_drafts,
      from(plan in Plan,
        where:
          plan.agent_id == ^agent_id and plan.privy_user_id == ^owner_id and
            plan.state in ^@draft_states
      ),
      set: [state: "archived", updated_at: now]
    )
    |> Ecto.Multi.insert(:plan, plan_changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{plan: plan}} -> {:ok, plan}
      {:error, :plan, changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def get_plan(plan_id, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor) do
      case load_plan(plan_id, owner_id) do
        nil -> {:error, :not_found}
        %Plan{} = plan -> {:ok, serialize_plan(plan)}
      end
    end
  end

  def update_plan(plan_id, attrs, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         %Plan{} = plan <- load_plan(plan_id, owner_id),
         %{} = agent <- Launch.get_agent(current_actor, plan.agent_id),
         update_attrs <- normalize_plan_attrs(attrs, agent, false),
         {:ok, plan} <-
           plan
           |> Plan.update_changeset(
             Map.merge(update_attrs, %{
               agent_name: agent.name,
               identity_snapshot: identity_snapshot(agent),
               metadata_draft:
                 metadata_draft(Map.get(update_attrs, "metadata_draft") || plan.metadata_draft)
             })
           )
           |> Repo.update() do
      {:ok, serialize_plan(plan)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def upload_asset(attrs, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         {:ok, asset_attrs} <- normalize_asset_attrs(attrs, owner_id),
         {:ok, asset} <-
           %Asset{}
           |> Asset.changeset(asset_attrs)
           |> Repo.insert() do
      {:ok, serialize_asset(asset)}
    end
  end

  def update_metadata(plan_id, attrs, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         %Plan{} = plan <- load_plan(plan_id, owner_id),
         {:ok, metadata} <- required_metadata(attrs),
         {:ok, plan} <-
           plan
           |> Plan.update_changeset(%{metadata_draft: metadata})
           |> Repo.update() do
      {:ok,
       %{
         plan: serialize_plan(plan),
         metadata_preview: metadata_preview_payload(plan)
       }}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def supporting_evidence_for_agent(agent_id, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor) do
      evidence =
        Plan
        |> where([plan], plan.agent_id == ^agent_id)
        |> where([plan], plan.privy_user_id == ^owner_id)
        |> where([plan], plan.state != "archived")
        |> where([plan], not is_nil(plan.techtree_evidence_packet_ref))
        |> order_by([plan], desc: plan.updated_at)
        |> limit(5)
        |> Repo.all()
        |> Enum.flat_map(&supporting_evidence/1)

      {:ok, evidence}
    end
  end

  def metadata_preview(plan_id, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor) do
      case load_plan(plan_id, owner_id) do
        nil -> {:error, :not_found}
        %Plan{} = plan -> {:ok, metadata_preview_payload(plan)}
      end
    end
  end

  def validate_plan(plan_id, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         %Plan{} = plan <- load_plan(plan_id, owner_id),
         {:ok, validation} <- build_validation(plan, current_actor),
         {:ok, updated} <-
           plan
           |> Plan.update_changeset(%{
             state: validation.state,
             validation_summary: validation.summary
           })
           |> Repo.update() do
      {:ok,
       %{
         plan: serialize_plan(updated),
         validation: validation.summary
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def publish_plan(plan_id, current_actor) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         {:ok, %{validation: validation}} <- validate_plan(plan_id, current_actor),
         true <- validation["launchable"] || {:error, :not_launchable},
         %Plan{} = stored <- load_plan(plan_id, owner_id),
         {:ok, updated} <-
           stored
           |> Plan.update_changeset(%{
             state: "launchable",
             published_metadata_url: metadata_preview_url(stored.plan_id)
           })
           |> Repo.update() do
      {:ok,
       %{
         plan: serialize_plan(updated),
         metadata_url: updated.published_metadata_url
       }}
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
      false -> {:error, :not_launchable}
    end
  end

  def launch_plan(plan_id, attrs, current_actor, request_ip) do
    with {:ok, owner_id} <- owner_id_for(current_actor),
         %Plan{} = plan <- load_plan(plan_id, owner_id),
         {:ok, %{validation: validation}} <- validate_plan(plan_id, current_actor),
         true <- validation["launchable"] || {:error, :not_launchable},
         launch_attrs <- build_launch_attrs(plan, attrs),
         {:ok, %{plan: updated, launch: job}} <-
           create_launch_and_mark_plan_launched(plan, launch_attrs, current_actor, request_ip),
         :ok <- Launch.queue_processing(job.job_id) do
      {:ok, %{plan: serialize_plan(updated), launch: job}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :not_launchable}
    end
  end

  defp create_launch_and_mark_plan_launched(plan, launch_attrs, current_actor, request_ip) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:launch, fn _repo, _changes ->
      Launch.create_launch_job(launch_attrs, current_actor, request_ip, queue?: false)
    end)
    |> Ecto.Multi.update(:plan, fn %{launch: job} ->
      Plan.update_changeset(plan, %{
        state: "launched",
        launch_job_id: job.job_id,
        published_metadata_url: plan.published_metadata_url || metadata_preview_url(plan.plan_id)
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{plan: plan, launch: job}} -> {:ok, %{plan: plan, launch: job}}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp build_validation(plan, current_actor) do
    preview_attrs = %{
      "agent_id" => plan.agent_id,
      "token_name" => plan.token_name,
      "token_symbol" => plan.token_symbol,
      "minimum_raise_usdc" => plan.minimum_raise_usdc,
      "agent_safe_address" => plan.agent_safe_address,
      "launch_notes" => plan.launch_notes
    }

    case Launch.preview_launch(preview_attrs, current_actor) do
      {:ok, preview} ->
        metadata = metadata_draft(plan.metadata_draft)
        image_url = metadata["image_url"] || Map.get(plan.identity_snapshot || %{}, "image_url")

        blockers =
          []
          |> maybe_block(blank?(metadata["title"]), "Add a hosted title for the launch page.")
          |> maybe_block(
            blank?(metadata["description"]),
            "Add a hosted description for the launch page."
          )
          |> maybe_block(blank?(image_url), "Add an image for the launch page.")

        warnings = []
        supporting_evidence = supporting_evidence(plan)

        state = if blockers == [], do: "launchable", else: "validated"

        {:ok,
         %{
           state: state,
           summary: %{
             "launchable" => blockers == [],
             "state" => state,
             "blockers" => blockers,
             "warnings" => warnings,
             "supporting_evidence" => supporting_evidence,
             "identity_status" => %{
               "agent_id" => plan.agent_id,
               "agent_name" => plan.agent_name,
               "current_image_url" => Map.get(plan.identity_snapshot || %{}, "image_url"),
               "current_web_endpoint" => Map.get(plan.identity_snapshot || %{}, "web_endpoint"),
               "current_agent_uri" => Map.get(plan.identity_snapshot || %{}, "agent_uri")
             },
             "trust_follow_up" => preview.reputation_prompt,
             "next_steps" => preview.next_steps || [],
             "permanence_notes" => preview.permanence_notes || []
           }
         }}

      {:error, {:agent_not_eligible, agent}} ->
        {:ok,
         %{
           state: "validated",
           summary: %{
             "launchable" => false,
             "state" => "validated",
             "blockers" => ["Selected agent is not eligible for launch."],
             "warnings" => [],
             "supporting_evidence" => supporting_evidence(plan),
             "agent" => agent
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_launch_attrs(plan, attrs) do
    %{
      "agent_id" => plan.agent_id,
      "token_name" => plan.token_name,
      "token_symbol" => plan.token_symbol,
      "minimum_raise_usdc" => plan.minimum_raise_usdc,
      "agent_safe_address" => plan.agent_safe_address,
      "launch_notes" => plan.launch_notes,
      "wallet_address" => Map.get(attrs, "wallet_address"),
      "registry_address" => Map.get(attrs, "registry_address"),
      "token_id" => Map.get(attrs, "token_id"),
      "message" => Map.get(attrs, "message"),
      "signature" => Map.get(attrs, "signature"),
      "nonce" => Map.get(attrs, "nonce"),
      "issued_at" => Map.get(attrs, "issued_at")
    }
  end

  defp normalize_plan_attrs(attrs, agent, require_all? \\ true) do
    minimum_raise =
      normalize_usdc_amount(Map.get(attrs, "minimum_raise_usdc"))

    fields = %{
      "agent_name" => agent.name,
      "token_name" => trim(Map.get(attrs, "token_name")),
      "token_symbol" => trim(Map.get(attrs, "token_symbol")),
      "minimum_raise_usdc" => minimum_raise && minimum_raise.display,
      "minimum_raise_usdc_raw" => minimum_raise && minimum_raise.raw,
      "agent_safe_address" => normalize_address(Map.get(attrs, "agent_safe_address")),
      "launch_notes" => trim(Map.get(attrs, "launch_notes")),
      "techtree_evidence_packet_ref" => trim(Map.get(attrs, "techtree_evidence_packet_ref")),
      "metadata_draft" => metadata_draft(Map.get(attrs, "metadata_draft"))
    }

    if require_all? and
         Enum.any?(
           ~w(token_name token_symbol minimum_raise_usdc agent_safe_address),
           &blank?(fields[&1])
         ) do
      {:error, :invalid_plan}
    else
      fields
    end
  end

  defp metadata_draft(value) when is_map(value) do
    %{
      "title" => trim(Map.get(value, "title")),
      "subtitle" => trim(Map.get(value, "subtitle")),
      "description" => trim(Map.get(value, "description")),
      "website_url" => trim(Map.get(value, "website_url")),
      "image_asset_id" => trim(Map.get(value, "image_asset_id")),
      "image_url" => trim(Map.get(value, "image_url"))
    }
    |> Enum.reject(fn {_key, val} -> is_nil(val) end)
    |> Map.new()
  end

  defp metadata_draft(_value), do: %{}

  defp required_metadata(%{"metadata" => metadata}) when is_map(metadata),
    do: {:ok, metadata_draft(metadata)}

  defp required_metadata(_attrs), do: {:error, :metadata_required}

  defp launch_chain_id do
    InfrastructureConfig.launch_chain_id!()
  end

  defp identity_snapshot(agent) do
    %{
      "agent_id" => agent.agent_id,
      "name" => agent.name,
      "image_url" => agent.image_url,
      "agent_uri" => agent.agent_uri,
      "web_endpoint" => agent.web_endpoint,
      "ens" => agent.ens,
      "description" => agent.description,
      "owner_address" => agent.owner_address,
      "operator_addresses" => agent.operator_addresses || [],
      "source" => agent.source
    }
  end

  defp normalize_asset_attrs(%{"source_url" => source_url}, owner_id)
       when is_binary(source_url) and source_url != "" do
    {:ok,
     %{
       asset_id: "asset_" <> Ecto.UUID.generate(),
       privy_user_id: owner_id,
       file_name: filename_from_url(source_url),
       media_type: "text/uri-list",
       source_url: source_url,
       public_url: source_url
     }}
  end

  defp normalize_asset_attrs(attrs, owner_id) do
    with {:ok, file_name} <- required_text(Map.get(attrs, "file_name"), 255),
         {:ok, media_type} <- required_text(Map.get(attrs, "media_type"), 255),
         true <- media_type in @allowed_media_types || {:error, :invalid_media_type},
         {:ok, encoded} <- required_text(Map.get(attrs, "content_base64"), 10_000_000),
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, stored} <- AssetStorage.persist(file_name, media_type, bytes) do
      {:ok,
       %{
         asset_id: stored.asset_id,
         privy_user_id: owner_id,
         file_name: file_name,
         media_type: media_type,
         storage_path: stored.storage_path,
         public_url: stored.public_url,
         byte_size: byte_size(bytes),
         sha256: stored.sha256
       }}
    else
      false -> {:error, :invalid_media_type}
      {:error, {:asset_write_failed, _reason}} -> {:error, :asset_write_failed}
      {:error, _} = error -> error
    end
  end

  defp serialize_plan(%Plan{} = plan) do
    %{
      plan_id: plan.plan_id,
      state: plan.state,
      agent_id: plan.agent_id,
      agent_name: plan.agent_name,
      chain_id: plan.chain_id,
      token_name: plan.token_name,
      token_symbol: plan.token_symbol,
      minimum_raise_usdc: plan.minimum_raise_usdc,
      minimum_raise_usdc_raw: plan.minimum_raise_usdc_raw,
      agent_safe_address: plan.agent_safe_address,
      launch_notes: plan.launch_notes,
      techtree_evidence_packet_ref: plan.techtree_evidence_packet_ref,
      identity_snapshot: plan.identity_snapshot || %{},
      metadata_draft: plan.metadata_draft || %{},
      validation_summary: plan.validation_summary || %{},
      published_metadata_url: plan.published_metadata_url,
      launch_job_id: plan.launch_job_id,
      inserted_at: iso(plan.inserted_at),
      updated_at: iso(plan.updated_at)
    }
  end

  defp serialize_asset(%Asset{} = asset) do
    %{
      asset_id: asset.asset_id,
      file_name: asset.file_name,
      media_type: asset.media_type,
      public_url: asset.public_url,
      byte_size: asset.byte_size,
      sha256: asset.sha256
    }
  end

  defp metadata_preview_payload(%Plan{} = plan) do
    metadata = metadata_draft(plan.metadata_draft)
    snapshot = plan.identity_snapshot || %{}

    %{
      plan_id: plan.plan_id,
      title: metadata["title"] || snapshot["name"] || plan.token_name,
      subtitle: metadata["subtitle"] || "Autolaunch prelaunch preview",
      description:
        metadata["description"] ||
          snapshot["description"] ||
          "Hosted launch metadata for Autolaunch.",
      image_url: metadata["image_url"] || snapshot["image_url"],
      website_url: metadata["website_url"] || snapshot["web_endpoint"],
      agent_id: plan.agent_id,
      token_name: plan.token_name,
      token_symbol: plan.token_symbol,
      state: plan.state
    }
  end

  defp supporting_evidence(%Plan{techtree_evidence_packet_ref: ref}) when is_binary(ref) do
    case trim(ref) do
      nil ->
        []

      "" ->
        []

      value ->
        [
          %{
            kind: "techtree_evidence_packet",
            label: "Techtree evidence",
            ref: value,
            source: "techtree"
          }
        ]
    end
  end

  defp supporting_evidence(%Plan{}), do: []

  defp load_plan(plan_id, privy_user_id) do
    Repo.one(
      from plan in Plan,
        where: plan.plan_id == ^plan_id and plan.privy_user_id == ^privy_user_id
    )
  end

  defp owner_id_for(%HumanUser{privy_user_id: privy_user_id})
       when is_binary(privy_user_id) and privy_user_id != "",
       do: {:ok, privy_user_id}

  defp owner_id_for(%{
         "chain_id" => chain_id,
         "registry_address" => registry_address,
         "token_id" => token_id
       }) do
    with {:ok, chain_id} <- normalize_agent_owner_part(chain_id),
         {:ok, registry_address} <- normalize_agent_owner_part(registry_address),
         {:ok, token_id} <- normalize_agent_owner_part(token_id) do
      {:ok, "agent:#{chain_id}:#{registry_address}:#{token_id}"}
    end
  end

  defp owner_id_for(%{
         chain_id: chain_id,
         registry_address: registry_address,
         token_id: token_id
       }) do
    owner_id_for(%{
      "chain_id" => chain_id,
      "registry_address" => registry_address,
      "token_id" => token_id
    })
  end

  defp owner_id_for(_actor), do: {:error, :unauthorized}

  defp normalize_agent_owner_part(value) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp normalize_agent_owner_part(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :unauthorized}
      trimmed -> {:ok, String.downcase(trimmed)}
    end
  end

  defp normalize_agent_owner_part(_value), do: {:error, :unauthorized}

  defp required_text(value, max) when is_integer(max) do
    value = trim(value)

    cond do
      blank?(value) -> {:error, :invalid_plan}
      String.length(value) > max -> {:error, :invalid_plan}
      true -> {:ok, value}
    end
  end

  defp maybe_block(list, true, message), do: list ++ [message]
  defp maybe_block(list, _condition, _message), do: list

  defp normalize_usdc_amount(nil), do: nil

  defp normalize_usdc_amount(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Decimal.parse(trimmed) do
          {%Decimal{} = decimal, ""} ->
            scaled = Decimal.mult(decimal, Decimal.new("1000000"))

            cond do
              Decimal.compare(decimal, Decimal.new(0)) != :gt ->
                nil

              Decimal.equal?(scaled, Decimal.round(scaled, 0)) ->
                %{
                  display: decimal |> Decimal.normalize() |> Decimal.to_string(:normal),
                  raw: scaled |> Decimal.round(0) |> Decimal.to_integer() |> Integer.to_string()
                }

              true ->
                nil
            end

          _ ->
            nil
        end
    end
  end

  defp normalize_usdc_amount(value) when is_number(value),
    do: normalize_usdc_amount(to_string(value))

  defp trim(value), do: Evm.normalize_string(value)

  defp normalize_address(value), do: Evm.normalize_address(value)

  defp blank?(value), do: is_nil(value) or value == ""

  defp metadata_preview_url(plan_id), do: "/v1/app/prelaunch/plans/#{plan_id}/metadata-preview"

  defp filename_from_url(source_url) do
    source_url
    |> URI.parse()
    |> Map.get(:path, "")
    |> Path.basename()
    |> case do
      "" -> "remote-asset"
      value -> value
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: nil
end
