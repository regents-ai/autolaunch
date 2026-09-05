defmodule Autolaunch.LaunchDraft do
  alias Autolaunch.{LaunchDraftImage, LaunchDraftImageStorage}

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @account_token_fields [
    :name,
    :symbol,
    :description,
    :website,
    :required_regent_raised
  ]

  @treasury_fields [
    :treasury,
    :treasury_path,
    :eoa_acknowledgement
  ]

  @account_clean_v1_fields @account_token_fields ++ @treasury_fields

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  @metadata_limits [name: 64, symbol: 16, description: 512, website: 256]
  @address ~r/\A0x[0-9a-fA-F]{40}\z/
  @zero_address "0x" <> String.duplicate("0", 40)
  @amount ~r/\A[0-9]+(\.[0-9]{1,18})?\z/

  @doc "Whether the persisted token metadata stage is ready for launch review."
  def token_details_complete?(draft) do
    Enum.all?(@metadata_limits, fn {field, limit} ->
      value = Map.get(draft, field)
      is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit
    end) and image_complete?(draft) and valid_raise?(Map.get(draft, :required_regent_raised))
  end

  @doc "Whether the persisted treasury stage is ready for launch review."
  def treasury_complete?(draft) do
    treasury = Map.get(draft, :treasury)
    path = Map.get(draft, :treasury_path)

    is_binary(treasury) and Regex.match?(@address, treasury) and
      String.downcase(treasury) != @zero_address and path in [:safe, :contract, :eoa] and
      (path != :eoa or Map.get(draft, :eoa_acknowledgement) == @eoa_acknowledgement)
  end

  @doc "Whether both persisted preparation stages are complete."
  def launch_ready?(draft), do: token_details_complete?(draft) and treasury_complete?(draft)

  @doc "Whether this draft carries the only image shape its provenance permits."
  def image_complete?(%{
        id: draft_id,
        human_account_id: human_account_id,
        launch_draft_image_id: image_id,
        launch_draft_image: %LaunchDraftImage{} = owned_image,
        image: image
      })
      when is_binary(draft_id) and is_integer(human_account_id) and is_binary(image_id) and
             is_binary(image) do
    owned_image.id == image_id and
      owned_image.human_account_id == human_account_id and
      owned_image.launch_draft_id == draft_id and
      owned_image.digest =~ ~r/\A[0-9a-f]{64}\z/ and
      image == LaunchDraftImageStorage.public_url(owned_image) and
      byte_size(image) <= 256
  end

  def image_complete?(_draft), do: false

  defp valid_raise?(value) when is_binary(value),
    do: Regex.match?(@amount, value) and Regex.match?(~r/[1-9]/, value)

  defp valid_raise?(_value), do: false

  postgres do
    table "launch_drafts"
    repo Autolaunch.Repo

    custom_indexes do
      index [:human_account_id]
      index [:launch_draft_image_id]
    end
  end

  actions do
    create :create_for_owner do
      accept @account_clean_v1_fields
      change Autolaunch.LaunchDraft.Changes.EnsurePartialDefaults
      validate Autolaunch.LaunchDraft.Validations.PartialFields
      change Autolaunch.LaunchDraft.Changes.AssignOwner
      upsert? true
      upsert_identity :one_account_owned_draft_per_human
      upsert_fields []
      return_skipped_upsert? true
    end

    read :mine do
      filter expr(human_account_id == ^actor(:human_account_id))
      prepare build(sort: [updated_at: :desc, id: :asc], load: [:launch_draft_image])
    end

    read :mine_by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(human_account_id == ^actor(:human_account_id) and id == ^arg(:id))
      prepare build(load: [:launch_draft_image])
    end

    read :mine_account_owned do
      get? true

      filter expr(human_account_id == ^actor(:human_account_id))

      prepare build(load: [:launch_draft_image])
    end

    read :mine_by_id_for_update do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(human_account_id == ^actor(:human_account_id) and id == ^arg(:id))

      prepare build(load: [:launch_draft_image])
      prepare fn query, _context -> Ash.Query.lock(query, :for_update) end
    end

    update :autosave_token_details do
      accept @account_token_fields
      require_atomic? false
      validate Autolaunch.LaunchDraft.Validations.PartialFields
    end

    update :autosave_treasury do
      accept @treasury_fields
      require_atomic? false
      validate Autolaunch.LaunchDraft.Validations.PartialFields
    end

    update :attach_image do
      argument :launch_draft_image_id, :uuid, allow_nil?: false
      require_atomic? false
      change Autolaunch.LaunchDraft.Changes.AttachOwnedImage
    end

    update :revise_by_owner do
      accept @account_clean_v1_fields
      require_atomic? false
      validate Autolaunch.LaunchDraft.Validations.AccountOwnedImage
      validate Autolaunch.LaunchDraft.Validations.CleanV1Fields

      validate attribute_equals(:eoa_acknowledgement, @eoa_acknowledgement),
        where: [attribute_equals(:treasury_path, :eoa)]
    end
  end

  policies do
    policy action([
             :create_for_owner,
             :mine,
             :mine_by_id,
             :mine_account_owned,
             :mine_by_id_for_update,
             :autosave_token_details,
             :autosave_treasury,
             :attach_image,
             :revise_by_owner
           ]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action([
             :mine,
             :mine_by_id,
             :mine_account_owned,
             :mine_by_id_for_update,
             :autosave_token_details,
             :autosave_treasury,
             :attach_image,
             :revise_by_owner
           ]) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      source :token_name
      allow_nil? false
      default ""
      public? true
      constraints allow_empty?: true
    end

    attribute :symbol, :string do
      allow_nil? false
      default ""
      public? true
      constraints allow_empty?: true
    end

    attribute :description, :string do
      source :summary
      public? true
    end

    attribute :website, :string, public?: true
    attribute :image, :string, public?: true
    attribute :treasury, :string, public?: true

    attribute :treasury_path, :atom do
      allow_nil? false
      public? true
      default :safe
      constraints one_of: [:safe, :eoa, :contract]
    end

    attribute :required_regent_raised, :string, public?: true

    attribute :eoa_acknowledgement, :string do
      public? true
      constraints max_length: 512, trim?: false
    end

    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :launch_draft_image, Autolaunch.LaunchDraftImage do
      allow_nil? true
    end
  end

  identities do
    identity :one_account_owned_draft_per_human, [:human_account_id]
  end
end
