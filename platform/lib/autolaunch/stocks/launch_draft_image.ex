defmodule Autolaunch.Stocks.LaunchDraftImage do
  @moduledoc """
  One immutable image uploaded by a signed-in Stocks launch creator.

  The same provenance model as `Autolaunch.LaunchDraftImage`, on the Stocks
  lane's own table: bytes never change or disappear after a URL has been
  issued, owner reads are private, and the only public read requires both the
  unguessable UUID and the full SHA-256 digest carried by the
  content-addressed `/stock-images/...` URL.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  postgres do
    table "stock_launch_draft_images"
    repo Autolaunch.Repo

    references do
      reference :human_account, on_delete: :restrict
      reference :stock_launch_draft, on_delete: :restrict
    end
  end

  actions do
    create :store_for_owner do
      accept [:bytes, :content_type, :original_filename, :stock_launch_draft_id]
      change Autolaunch.LaunchDraftImage.Changes.AssignOwner
      change Autolaunch.Stocks.LaunchDraftImage.Changes.PrepareImmutableImage
    end

    read :read do
      primary? true
      filter expr(human_account_id == ^actor(:human_account_id))
    end

    read :mine do
      get? true
      argument :stock_launch_draft_id, :uuid, allow_nil?: false

      filter expr(
               human_account_id == ^actor(:human_account_id) and
                 stock_launch_draft_id == ^arg(:stock_launch_draft_id)
             )

      filter expr(stock_launch_draft.stock_launch_draft_image_id == id)
    end

    read :mine_by_id do
      get? true
      argument :stock_launch_draft_id, :uuid, allow_nil?: false
      argument :id, :uuid, allow_nil?: false

      filter expr(
               human_account_id == ^actor(:human_account_id) and
                 stock_launch_draft_id == ^arg(:stock_launch_draft_id) and id == ^arg(:id)
             )
    end

    read :mine_for_reuse do
      get? true
      argument :stock_launch_draft_id, :uuid, allow_nil?: false
      argument :digest, :string, allow_nil?: false

      filter expr(
               human_account_id == ^actor(:human_account_id) and
                 stock_launch_draft_id == ^arg(:stock_launch_draft_id) and
                 digest == ^arg(:digest)
             )

      prepare build(
                select: [
                  :id,
                  :digest,
                  :content_type,
                  :byte_size,
                  :bytes,
                  :original_filename,
                  :human_account_id,
                  :stock_launch_draft_id
                ]
              )
    end

    read :public_by_id_and_digest do
      get? true
      argument :id, :uuid, allow_nil?: false
      argument :digest, :string, allow_nil?: false
      filter expr(id == ^arg(:id) and digest == ^arg(:digest))
      prepare build(select: [:id, :digest, :content_type, :byte_size, :bytes])
    end
  end

  policies do
    policy action([:store_for_owner, :read, :mine, :mine_by_id, :mine_for_reuse]) do
      authorize_if Autolaunch.Accounts.Checks.HumanActor
    end

    policy action([:read, :mine, :mine_by_id, :mine_for_reuse]) do
      authorize_if expr(human_account_id == ^actor(:human_account_id))
    end

    policy action(:public_by_id_and_digest) do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :digest, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/, max_length: 64
    end

    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\Aimage\/(png|jpeg|webp)\z/
    end

    attribute :byte_size, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 2_097_152
    end

    attribute :bytes, :binary do
      allow_nil? false
      sensitive? true
      select_by_default? false
    end

    attribute :original_filename, :string do
      allow_nil? false
      constraints min_length: 1, max_length: 255
    end

    timestamps()
  end

  relationships do
    belongs_to :human_account, Autolaunch.Accounts.HumanAccount do
      allow_nil? false
      attribute_type :integer
    end

    belongs_to :stock_launch_draft, Autolaunch.Stocks.LaunchDraft do
      allow_nil? false
      read_action :mine
    end
  end

  identities do
    identity :one_version_per_stock_draft, [:stock_launch_draft_id, :digest]
  end
end
