defmodule Autolaunch.Prelaunch do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Launch
  alias Autolaunch.Prelaunch.Asset
  alias Autolaunch.Prelaunch.Plan
  alias Autolaunch.Repo

  @chain_id 11_155_111
  @draft_states ~w(draft validated launchable)
  @uploads_dir "priv/static/prelaunch-assets"
  @allowed_media_types ~w(image/png image/jpeg image/webp image/gif)

  def list_plans(%HumanUser{} = human) do
    {:ok,
     Plan
     |> where([plan], plan.privy_user_id == ^human.privy_user_id)
     |> order_by([plan], desc: plan.updated_at)
     |> Repo.all()
     |> Enum.map(&serialize_plan/1)}
  end

  def list_plans(_human), do: {:error, :unauthorized}

  def create_plan(attrs, %HumanUser{} = human) do
    with {:ok, agent_id} <- required_text(Map.get(attrs, "agent_id"), 255),
         %{} = agent <- Launch.get_agent(human, agent_id),
         attrs <- normalize_plan_attrs(attrs, agent),
         :ok <- archive_existing_agent_drafts(agent_id, human.privy_user_id),
         {:ok, plan} <-
           %Plan{}
           |> Plan.create_changeset(
             Map.merge(attrs, %{
               plan_id: "plan_" <> Ecto.UUID.generate(),
               privy_user_id: human.privy_user_id,
               chain_id: @chain_id,
               identity_snapshot: identity_snapshot(agent),
               metadata_draft: metadata_draft(Map.get(attrs, "metadata_draft"))
             })
           )
           |> Repo.insert() do
      {:ok, serialize_plan(plan)}
    else
      nil -> {:error, :agent_not_found}
      {:error, _} = error -> error
    end
  end

  def create_plan(_attrs, _human), do: {:error, :unauthorized}

  def get_plan(plan_id, %HumanUser{} = human) do
    case load_plan(plan_id, human.privy_user_id) do
      nil -> {:error, :not_found}
      %Plan{} = plan -> {:ok, serialize_plan(plan)}
    end
  end

  def get_plan(_plan_id, _human), do: {:error, :unauthorized}

  def update_plan(plan_id, attrs, %HumanUser{} = human) do
    with %Plan{} = plan <- load_plan(plan_id, human.privy_user_id),
         %{} = agent <- Launch.get_agent(human, plan.agent_id),
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

  def update_plan(_plan_id, _attrs, _human), do: {:error, :unauthorized}

  def upload_asset(attrs, %HumanUser{} = human) do
    with {:ok, asset_attrs} <- normalize_asset_attrs(attrs, human),
         {:ok, asset} <-
           %Asset{}
           |> Asset.changeset(asset_attrs)
           |> Repo.insert() do
      {:ok, serialize_asset(asset)}
    end
  end

  def upload_asset(_attrs, _human), do: {:error, :unauthorized}

  def update_metadata(plan_id, attrs, %HumanUser{} = human) do
    with %Plan{} = plan <- load_plan(plan_id, human.privy_user_id),
         metadata <- metadata_draft(Map.get(attrs, "metadata") || attrs),
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
    end
  end

  def update_metadata(_plan_id, _attrs, _human), do: {:error, :unauthorized}

  def metadata_preview(plan_id, %HumanUser{} = human) do
    case load_plan(plan_id, human.privy_user_id) do
      nil -> {:error, :not_found}
      %Plan{} = plan -> {:ok, metadata_preview_payload(plan)}
    end
  end

  def metadata_preview(_plan_id, _human), do: {:error, :unauthorized}

  def validate_plan(plan_id, %HumanUser{} = human) do
    with %Plan{} = plan <- load_plan(plan_id, human.privy_user_id),
         {:ok, validation} <- build_validation(plan, human),
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

  def validate_plan(_plan_id, _human), do: {:error, :unauthorized}

  def publish_plan(plan_id, %HumanUser{} = human) do
    with {:ok, %{validation: validation}} <- validate_plan(plan_id, human),
         true <- validation["launchable"] || {:error, :not_launchable},
         %Plan{} = stored <- load_plan(plan_id, human.privy_user_id),
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

  def publish_plan(_plan_id, _human), do: {:error, :unauthorized}

  def launch_plan(plan_id, attrs, %HumanUser{} = human, request_ip) do
    with %Plan{} = plan <- load_plan(plan_id, human.privy_user_id),
         {:ok, %{validation: validation}} <- validate_plan(plan_id, human),
         true <- validation["launchable"] || {:error, :not_launchable},
         launch_attrs <- build_launch_attrs(plan, attrs),
         {:ok, job} <- Launch.create_launch_job(launch_attrs, human, request_ip),
         {:ok, updated} <-
           plan
           |> Plan.update_changeset(%{
             state: "launched",
             launch_job_id: job.job_id,
             published_metadata_url:
               plan.published_metadata_url || metadata_preview_url(plan.plan_id)
           })
           |> Repo.update() do
      {:ok, %{plan: serialize_plan(updated), launch: job}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      false -> {:error, :not_launchable}
    end
  end

  def launch_plan(_plan_id, _attrs, _human, _request_ip), do: {:error, :unauthorized}

  defp build_validation(plan, %HumanUser{} = human) do
    preview_attrs = %{
      "agent_id" => plan.agent_id,
      "token_name" => plan.token_name,
      "token_symbol" => plan.token_symbol,
      "minimum_raise_usdc" => plan.minimum_raise_usdc,
      "recovery_safe_address" => plan.treasury_safe_address,
      "auction_proceeds_recipient" => plan.auction_proceeds_recipient,
      "ethereum_revenue_treasury" => plan.ethereum_revenue_treasury,
      "launch_notes" => plan.launch_notes
    }

    case Launch.preview_launch(preview_attrs, human) do
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
          |> maybe_block(
            blank?(plan.backup_safe_address),
            "Set a backup safe address."
          )

        warnings =
          []
          |> maybe_warn(
            same_address?(plan.treasury_safe_address, plan.auction_proceeds_recipient),
            "Treasury safe and auction proceeds recipient are the same address."
          )
          |> maybe_warn(
            same_address?(plan.treasury_safe_address, plan.ethereum_revenue_treasury),
            "Treasury safe and Ethereum revenue treasury are the same address."
          )
          |> maybe_warn(
            same_address?(plan.auction_proceeds_recipient, plan.ethereum_revenue_treasury),
            "Auction proceeds recipient and Ethereum revenue treasury are the same address."
          )

        state = if blockers == [], do: "launchable", else: "validated"

        {:ok,
         %{
           state: state,
           summary: %{
             "launchable" => blockers == [],
             "state" => state,
             "blockers" => blockers,
             "warnings" => warnings,
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
      "recovery_safe_address" => plan.treasury_safe_address,
      "auction_proceeds_recipient" => plan.auction_proceeds_recipient,
      "ethereum_revenue_treasury" => plan.ethereum_revenue_treasury,
      "launch_notes" => plan.launch_notes,
      "wallet_address" => Map.get(attrs, "wallet_address"),
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
      "treasury_safe_address" => normalize_address(Map.get(attrs, "treasury_safe_address")),
      "auction_proceeds_recipient" =>
        normalize_address(Map.get(attrs, "auction_proceeds_recipient")),
      "ethereum_revenue_treasury" =>
        normalize_address(Map.get(attrs, "ethereum_revenue_treasury")),
      "backup_safe_address" => normalize_optional_address(Map.get(attrs, "backup_safe_address")),
      "launch_notes" => trim(Map.get(attrs, "launch_notes")),
      "metadata_draft" => metadata_draft(Map.get(attrs, "metadata_draft"))
    }

    if require_all? and
         Enum.any?(
           ~w(token_name token_symbol minimum_raise_usdc treasury_safe_address auction_proceeds_recipient ethereum_revenue_treasury),
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

  defp normalize_asset_attrs(%{"source_url" => source_url}, %HumanUser{} = human)
       when is_binary(source_url) and source_url != "" do
    {:ok,
     %{
       asset_id: "asset_" <> Ecto.UUID.generate(),
       privy_user_id: human.privy_user_id,
       file_name: filename_from_url(source_url),
       media_type: "text/uri-list",
       source_url: source_url,
       public_url: source_url
     }}
  end

  defp normalize_asset_attrs(attrs, %HumanUser{} = human) do
    with {:ok, file_name} <- required_text(Map.get(attrs, "file_name"), 255),
         {:ok, media_type} <- required_text(Map.get(attrs, "media_type"), 255),
         true <- media_type in @allowed_media_types || {:error, :invalid_media_type},
         {:ok, encoded} <- required_text(Map.get(attrs, "content_base64"), 10_000_000),
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, asset_id, storage_path, public_url, sha256} <-
           persist_asset(file_name, media_type, bytes) do
      {:ok,
       %{
         asset_id: asset_id,
         privy_user_id: human.privy_user_id,
         file_name: file_name,
         media_type: media_type,
         storage_path: storage_path,
         public_url: public_url,
         byte_size: byte_size(bytes),
         sha256: sha256
       }}
    else
      false -> {:error, :invalid_media_type}
      {:error, _} = error -> error
    end
  end

  defp persist_asset(file_name, media_type, bytes) do
    File.mkdir_p!(Path.expand(@uploads_dir, File.cwd!()))
    asset_id = "asset_" <> Ecto.UUID.generate()
    ext = extension_for(media_type, file_name)
    relative_path = Path.join(@uploads_dir, "#{asset_id}#{ext}")
    absolute_path = Path.expand(relative_path, File.cwd!())
    File.write!(absolute_path, bytes)

    {:ok, asset_id, relative_path, "/prelaunch-assets/#{asset_id}#{ext}",
     Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
  rescue
    _ -> {:error, :asset_write_failed}
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
      treasury_safe_address: plan.treasury_safe_address,
      auction_proceeds_recipient: plan.auction_proceeds_recipient,
      ethereum_revenue_treasury: plan.ethereum_revenue_treasury,
      backup_safe_address: plan.backup_safe_address,
      launch_notes: plan.launch_notes,
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

  defp load_plan(plan_id, privy_user_id) do
    Repo.one(
      from plan in Plan,
        where: plan.plan_id == ^plan_id and plan.privy_user_id == ^privy_user_id
    )
  end

  defp archive_existing_agent_drafts(agent_id, privy_user_id) do
    {_, _} =
      Repo.update_all(
        from(plan in Plan,
          where:
            plan.agent_id == ^agent_id and plan.privy_user_id == ^privy_user_id and
              plan.state in ^@draft_states
        ),
        set: [state: "archived", updated_at: DateTime.utc_now()]
      )

    :ok
  end

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

  defp maybe_warn(list, true, message), do: list ++ [message]
  defp maybe_warn(list, _condition, _message), do: list

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

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(_value), do: nil

  defp normalize_address(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.match?(trimmed, ~r/^0x[0-9a-fA-F]{40}$/) do
      String.downcase(trimmed)
    else
      nil
    end
  end

  defp normalize_address(_value), do: nil
  defp normalize_optional_address(nil), do: nil
  defp normalize_optional_address(""), do: nil
  defp normalize_optional_address(value), do: normalize_address(value)

  defp blank?(value), do: is_nil(value) or value == ""

  defp same_address?(left, right) when is_binary(left) and is_binary(right), do: left == right
  defp same_address?(_left, _right), do: false

  defp metadata_preview_url(plan_id), do: "/api/prelaunch/plans/#{plan_id}/metadata-preview"

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

  defp extension_for("image/png", _file_name), do: ".png"

  defp extension_for("image/jpeg", file_name),
    do: if(String.ends_with?(String.downcase(file_name), ".jpg"), do: ".jpg", else: ".jpeg")

  defp extension_for("image/webp", _file_name), do: ".webp"
  defp extension_for("image/gif", _file_name), do: ".gif"
  defp extension_for(_media_type, file_name), do: Path.extname(file_name)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_value), do: nil
end
