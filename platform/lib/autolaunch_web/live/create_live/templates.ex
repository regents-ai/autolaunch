defmodule AutolaunchWeb.Live.CreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.MarketCard
  import AutolaunchWeb.Components.XConnections

  alias Autolaunch.LaunchDraft

  @address_hint "0x followed by exactly 40 hexadecimal characters."

  @token_detail_fields [
    %{key: :name, param: "name", label: "Name", kind: :text, hint: nil},
    %{key: :symbol, param: "symbol", label: "Symbol", kind: :text, hint: nil},
    %{key: :description, param: "description", label: "Description", kind: :long_text, hint: nil},
    %{
      key: :website,
      param: "website",
      label: "Website",
      kind: :text,
      hint: "A link readers can open."
    },
    %{
      key: :required_regent_raised,
      param: "required_regent_raised",
      label: "Required raise in REGENT",
      kind: :text,
      hint: "Digits only, with at most 18 decimal places."
    }
  ]

  @treasury_field %{
    key: :treasury,
    param: "treasury",
    label: "Immutable treasury recipient",
    kind: :text,
    hint: @address_hint
  }

  @stored_params Enum.map(@token_detail_fields, & &1.param) ++
                   ["image", "treasury", "treasury_path", "eoa_acknowledgement"]

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  def token_detail_params, do: Enum.map(@token_detail_fields, & &1.param)
  def treasury_params, do: ["treasury", "treasury_path", "eoa_acknowledgement"]
  def draft_field_params, do: @stored_params

  def blank_draft_fields,
    do:
      @stored_params
      |> Map.new(&{&1, ""})
      |> Map.merge(%{"treasury_path" => "safe", "eoa_acknowledgement" => ""})

  def draft_values(nil), do: blank_draft_fields()

  def draft_values(draft) do
    Map.new(@stored_params, fn param ->
      value = Map.get(draft, String.to_existing_atom(param))

      {param,
       cond do
         is_nil(value) -> ""
         is_atom(value) -> Atom.to_string(value)
         true -> value
       end}
    end)
  end

  attr :account_control, :map, required: true
  attr :launch_drafts, :list, default: []
  attr :draft_values, :map, required: true
  attr :draft_errors, :map, required: true
  attr :draft_notice, :map, default: nil
  attr :launch_image_upload, :map, default: nil
  attr :x_connections, :list, default: []
  attr :x_oauth_enabled, :boolean, default: false
  attr :auction_limit_reached, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :status, :atom, default: :ready

  def create(assigns) do
    draft = List.first(assigns.launch_drafts)

    assigns =
      assigns
      |> assign(:active_draft, draft)
      |> assign(:token_complete?, draft && LaunchDraft.token_details_complete?(draft))
      |> assign(:treasury_complete?, draft && LaunchDraft.treasury_complete?(draft))
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:draft_x_connections, Map.new(assigns.x_connections, &{&1.role, &1}))

    ~H"""
    <section id="autolaunch-create" class="autolaunch-page launchpad-create">
      <header class="launchpad-create__header">
        <p class="autolaunch-kicker">Autolaunch · Create</p>
        <h1>Launch an auction</h1>
        <p>
          Add the public token details, choose the treasury, then review the exact transactions.
          Draft changes save privately to your account. Your wallet remains in control.
        </p>
      </header>

      <p :if={@auction_limit_reached} class="launchpad-limit" role="status">
        You already have an auction. One auction per account for now.
      </p>

      <.empty_state
        :if={@status == :error}
        copy="Your draft could not be loaded. Refresh and try again."
      />

      <section
        :if={@status != :error}
        class="launchpad-create__workspace"
        aria-labelledby="launch-draft-title"
      >
        <div class="launchpad-create__form-column">
          <form
            id="launch-token-details"
            phx-change="autosave_launch_token_details"
            phx-submit="autosave_launch_token_details"
            class="launchpad-form-section"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Public identity</p>
                <h2 id="launch-draft-title">Token details</h2>
              </div>
              <span>{stage_status(@token_complete?)}</span>
            </header>

            <div class="launchpad-form-grid">
              <.draft_field
                :for={field <- token_detail_fields()}
                field={field}
                form_id="launch-token-details"
                hint={field.hint}
                value={@draft_values[field.param]}
                error={@draft_errors[field.param]}
                autosave
              />
            </div>

            <div class="autolaunch-draft-field autolaunch-draft-field--wide launchpad-upload">
              <label for="launch-image-upload">Token image</label>
              <p class="autolaunch-draft-hint">
                PNG, JPEG, or WebP · maximum 2 MB · one permanent image per account.
                <strong>Recommended: 400 × 400 px</strong>
              </p>
              <div class="launchpad-upload__control">
                <img
                  :if={is_binary(@draft_values["image"]) && @draft_values["image"] != ""}
                  class="autolaunch-image-preview"
                  src={@draft_values["image"]}
                  alt="Saved token image"
                />
                <.live_file_input
                  :if={@launch_image_upload}
                  upload={@launch_image_upload}
                  id="launch-image-upload"
                />
              </div>
              <div :for={entry <- (@launch_image_upload && @launch_image_upload.entries) || []}>
                <.live_img_preview entry={entry} class="autolaunch-image-preview" />
                <p>{entry.client_name} · {upload_progress(entry.progress)}</p>
              </div>
              <p
                :for={error <- (@launch_image_upload && upload_errors(@launch_image_upload)) || []}
                class="autolaunch-draft-error"
                role="alert"
              >
                {upload_error(error)}
              </p>
            </div>
          </form>

          <form
            id="launch-image-url"
            phx-submit="fetch_image_url"
            class="launchpad-upload__url"
          >
            <label for="launch-image-url-input">Paste an image link</label>
            <div class="launchpad-upload__url-row">
              <input
                type="text"
                id="launch-image-url-input"
                name="url"
                autocomplete="off"
                placeholder="https://"
              />
              <button type="submit">Use this link</button>
            </div>
          </form>

          <.x_connections
            id="autolaunch-create-x-connections"
            connections={@x_connections}
            enabled={@x_oauth_enabled}
            compact
          />

          <form
            id="launch-treasury-details"
            phx-hook="AutolaunchLaunchDraft"
            phx-change="autosave_launch_treasury"
            phx-submit="autosave_launch_treasury"
            class="launchpad-form-section"
            data-saved-drafts={if(@active_draft, do: "1", else: "0")}
            data-draft-errors={to_string(@draft_errors != %{})}
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Proceeds</p>
                <h2>Treasury</h2>
              </div>
              <span>{stage_status(@treasury_complete?)}</span>
            </header>
            <.custody_path
              form_id="launch-treasury-details"
              path={@draft_values["treasury_path"]}
              acknowledgement={@draft_values["eoa_acknowledgement"]}
              error={@draft_errors["eoa_acknowledgement"]}
            />
            <.draft_field
              field={treasury_field()}
              form_id="launch-treasury-details"
              hint={treasury_field().hint}
              value={@draft_values["treasury"]}
              error={@draft_errors["treasury"]}
              autosave
            />
          </form>

          <section id="launch-transactions" class="launchpad-form-section launchpad-transactions">
            <header>
              <div>
                <p class="autolaunch-kicker">Wallet review</p>
                <h2>Launch transactions</h2>
              </div>
              <span>{if @launch_ready?, do: "Ready", else: "Details required"}</span>
            </header>
            <p>
              The wallet component shows the exact REGENT fee and transaction sequence before
              anything is submitted.
            </p>
            <.live_component
              :if={@launch_ready? && @active_draft}
              module={AutolaunchWeb.LaunchWalletComponent}
              id={"autolaunch-launch-wallet-#{@active_draft.id}"}
              draft={@active_draft}
              authenticated
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <button :if={!@launch_ready?} type="button" disabled>
              Complete token details and treasury
            </button>
          </section>

          <p
            :if={@draft_notice}
            class={"autolaunch-draft-notice autolaunch-draft-notice--#{@draft_notice.tone}"}
            role={notice_role(@draft_notice.tone)}
          >
            {@draft_notice.message}
          </p>
        </div>

        <aside class="launchpad-create__preview" aria-label="Live launch preview">
          <div>
            <p class="autolaunch-kicker">Live preview</p>
            <h2>Your auction</h2>
          </div>
          <.autolaunch_market_card
            kind={:draft}
            record={@draft_values}
            creator_connections={@draft_x_connections}
            preview
          />
          <p>Auctions and graduated tokens use this same public identity.</p>
        </aside>
      </section>
    </section>
    """
  end

  attr :form_id, :string, required: true
  attr :path, :string, default: "safe"
  attr :acknowledgement, :string, default: ""
  attr :error, :string, default: nil

  def custody_path(assigns) do
    id = "#{assigns.form_id}-eoa-acknowledgement"

    assigns =
      assign(assigns,
        id: id,
        warning_copy: @eoa_acknowledgement,
        described_by:
          Enum.join(
            ["#{id}-warning", assigns.error && "#{id}-error"] |> Enum.filter(& &1),
            " "
          )
      )

    ~H"""
    <fieldset class="autolaunch-custody-path">
      <legend>Choose treasury custody</legend>
      <strong>Create a 2-of-3 Safe on Base</strong>
      <a
        href="https://app.safe.global/new-safe/create?chain=base"
        target="_blank"
        rel="noopener noreferrer"
      >
        Open the official Safe creation flow
      </a>
      <p>Return here and verify the deployed address before launch.</p>
      <label>
        <input
          type="radio"
          name="launch_draft[treasury_path]"
          value="safe"
          checked={@path in [nil, "", "safe", :safe]}
        />
        <span>Use existing Safe</span>
      </label>
      <details>
        <summary>Advanced, high-risk treasury choices</summary>
        <label>
          <input
            type="radio"
            name="launch_draft[treasury_path]"
            value="contract"
            checked={@path in ["contract", :contract]}
          /> Existing contract or distribution destination — never verified
        </label>
        <label>
          <input
            type="radio"
            name="launch_draft[treasury_path]"
            value="eoa"
            checked={@path in ["eoa", :eoa]}
          /> Single-key EOA — never verified
        </label>
        <label for={@id}>
          To use an EOA, type this warning character-for-character:
        </label>
        <p id={"#{@id}-warning"} class="autolaunch-custody-warning">{@warning_copy}</p>
        <textarea
          id={@id}
          name="launch_draft[eoa_acknowledgement]"
          autocomplete="off"
          aria-invalid={@error && "true"}
          aria-describedby={@described_by}
        >{@acknowledgement}</textarea>
        <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">
          {@error}
        </p>
      </details>
    </fieldset>
    """
  end

  attr :field, :map, required: true
  attr :form_id, :string, required: true
  attr :hint, :string, default: nil
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :autosave, :boolean, default: false

  def draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.field.param}"

    assigns =
      assign(assigns, id: id, described_by: described_by(id, assigns.hint, assigns.error))

    ~H"""
    <div class={[
      "autolaunch-draft-field",
      @field.kind == :long_text && "autolaunch-draft-field--wide"
    ]}>
      <label for={@id}>{@field.label}</label>
      <textarea
        :if={@field.kind == :long_text}
        id={@id}
        name={"launch_draft[#{@field.param}]"}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce={@autosave && "400"}
      >{@value}</textarea>
      <input
        :if={@field.kind == :text}
        type="text"
        id={@id}
        name={"launch_draft[#{@field.param}]"}
        value={@value}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce={@autosave && "400"}
      />
      <p :if={@hint} id={"#{@id}-hint"} class="autolaunch-draft-hint">{@hint}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error">{@error}</p>
    </div>
    """
  end

  attr :copy, :string, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="autolaunch-empty">
      <p>{@copy}</p>
    </div>
    """
  end

  defp token_detail_fields, do: @token_detail_fields
  defp treasury_field, do: @treasury_field

  defp stage_status(true), do: "Complete"
  defp stage_status(_incomplete), do: "In progress"

  defp upload_progress(progress), do: "#{progress}%"
  defp upload_error(:too_large), do: "Choose an image no larger than 2 MB."
  defp upload_error(:not_accepted), do: "Choose a PNG, JPEG, or WebP image."
  defp upload_error(:too_many_files), do: "Choose one image."
  defp upload_error(_error), do: "That image could not be uploaded."

  defp described_by(id, hint, error) do
    case Enum.filter([hint && "#{id}-hint", error && "#{id}-error"], &is_binary/1) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  defp notice_role(:error), do: "alert"
  defp notice_role(_tone), do: "status"
end
