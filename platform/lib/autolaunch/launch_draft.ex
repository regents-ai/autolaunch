defmodule Autolaunch.LaunchDraft do
  alias Autolaunch.{LaunchDraftImage, LaunchDraftImageStorage, LaunchLinks, Ticker}

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @account_token_fields [:name, :symbol, :description, :website | LaunchLinks.fields()]

  @treasury_fields [
    :treasury,
    :treasury_path,
    :eoa_acknowledgement
  ]

  @draft_fields @account_token_fields ++ @treasury_fields

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  @metadata_limits [name: 64, description: 512]
  @address ~r/\A0x[0-9a-fA-F]{40}\z/
  @zero_address "0x" <> String.duplicate("0", 40)

  # The factory requires a website, so a launch without one names this site,
  # which the site's pages never show as a creator's website.
  @site_website "https://autolaunch.sh"

  @doc "Whether the persisted token metadata stage is ready for launch review."
  def token_details_complete?(draft), do: missing_token_details(draft) == []

  @doc "The token details the launch review still needs, by field."
  def missing_token_details(draft) do
    for({field, limit} <- @metadata_limits, not within?(Map.get(draft, field), limit), do: field) ++
      if(Ticker.complete?(Map.get(draft, :symbol)), do: [], else: [:symbol]) ++
      if(website_complete?(Map.get(draft, :website)), do: [], else: [:website]) ++
      Keyword.keys(LaunchLinks.problems(draft)) ++
      if(image_complete?(draft), do: [], else: [:image])
  end

  defp website_complete?(website) when website in [nil, ""], do: true
  defp website_complete?(website), do: within?(website, 256)

  @doc "Whether the persisted treasury stage is ready for launch review."
  def treasury_complete?(draft) do
    path = Map.get(draft, :treasury_path)

    treasury_address?(Map.get(draft, :treasury)) and path in [:safe, :contract, :eoa] and
      (path != :eoa or Map.get(draft, :eoa_acknowledgement) == @eoa_acknowledgement)
  end

  @doc "Whether `treasury` is a whole address a launch can send to."
  def treasury_address?(treasury),
    do:
      is_binary(treasury) and Regex.match?(@address, treasury) and
        String.downcase(treasury) != @zero_address

  @doc "The website a launch writes into its token: the creator's, or this site's."
  def onchain_website(%{website: website}) when website in [nil, ""], do: @site_website
  def onchain_website(%{website: website}), do: website

  defp within?(value, limit),
    do: is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= limit

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
      accept @draft_fields
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
      change Autolaunch.LaunchDraft.Changes.UpcaseTicker
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

    # A listed launch's draft starts over (`Autolaunch.LaunchedDrafts`), so the
    # form is blank again.
    update :clear do
      require_atomic? false
      change set_attribute(:name, "")
      change set_attribute(:symbol, "")
      change set_attribute(:description, nil)
      change set_attribute(:website, nil)
      change set_attribute(:telegram, nil)
      change set_attribute(:discord, nil)
      change set_attribute(:other_link_1, nil)
      change set_attribute(:other_link_2, nil)
      change set_attribute(:other_link_3, nil)
      change set_attribute(:image, nil)
      change set_attribute(:launch_draft_image_id, nil)
      change set_attribute(:treasury, nil)
      change set_attribute(:treasury_path, :safe)
      change set_attribute(:eoa_acknowledgement, nil)
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
             :clear
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
             :clear
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
    attribute :telegram, :string, public?: true
    attribute :discord, :string, public?: true
    attribute :other_link_1, :string, public?: true
    attribute :other_link_2, :string, public?: true
    attribute :other_link_3, :string, public?: true
    attribute :image, :string, public?: true
    attribute :treasury, :string, public?: true

    attribute :treasury_path, :atom do
      allow_nil? false
      public? true
      default :safe
      constraints one_of: [:safe, :eoa, :contract]
    end

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
