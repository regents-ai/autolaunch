defmodule AutolaunchWeb.Live.CreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.MarketCard

  alias AutolaunchWeb.UsdValue

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
      label: "Required raise",
      kind: :text,
      hint: nil
    }
  ]

  @raise_currency "REGENT"

  @treasury_field %{
    key: :treasury,
    param: "treasury",
    label: "Immutable treasury recipient",
    kind: :text,
    hint: @address_hint
  }

  @stored_params Enum.map(@token_detail_fields, & &1.param) ++
                   ["image", "treasury", "treasury_path", "eoa_acknowledgement"]

  @no_connections_acknowledgement "I realize my Revstake auction may not appear in the gallery or list, because reputation and social proof are important for raising initial funds for an agent"

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  def no_connections_acknowledgement, do: @no_connections_acknowledgement
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
  attr :image_notice, :map, default: nil
  attr :launch_image_upload, :map, default: nil
  attr :x_connections, :list, default: []
  attr :x_oauth_enabled, :boolean, default: false
  attr :auction_limit_reached, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :status, :atom, default: :ready
  attr :regent_usd_rate, :any, default: nil
  attr :has_connections, :boolean, default: false
  attr :connections_waived, :boolean, default: false
  attr :no_connections_typed, :string, default: ""

  def create(assigns) do
    draft = List.first(assigns.launch_drafts)

    assigns =
      assigns
      |> assign(:active_draft, draft)
      |> assign(:token_complete?, draft && LaunchDraft.token_details_complete?(draft))
      |> assign(:treasury_complete?, draft && LaunchDraft.treasury_complete?(draft))
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:draft_x_connections, Map.new(assigns.x_connections, &{&1.role, &1}))
      |> assign(:raise_currency, @raise_currency)

    ~H"""
    <section id="autolaunch-create">
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
          <.live_component
            module={AutolaunchWeb.CreatorConnectionsComponent}
            id="creator-connections"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
            notify
          />

          <form
            id="launch-token-details"
            phx-change="autosave_launch_token_details"
            phx-submit="autosave_launch_token_details"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Public identity</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label" id="launch-draft-title">Token details</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{stage_status(@token_complete?)}</span>
            </header>

            <div class="launchpad-form-grid">
              <.draft_field
                :for={field <- token_detail_fields(@raise_currency)}
                field={field}
                form_id="launch-token-details"
                hint={field.hint}
                value={@draft_values[field.param]}
                error={@draft_errors[field.param]}
                usd_rate={if field.key == :required_regent_raised, do: @regent_usd_rate, else: :none}
                autosave
              />
            </div>

            <.image_picker
              id="launch-image"
              upload={@launch_image_upload}
              image={@draft_values["image"]}
              notice={@image_notice}
            />
          </form>
          <.link_form id="launch-image" event="fetch_image_url" />

          <form
            id="launch-treasury-details"
            phx-hook="AutolaunchLaunchDraft"
            phx-change="autosave_launch_treasury"
            phx-submit="autosave_launch_treasury"
            class="launchpad-form-section rg-panel rg-panel--surface rg-field"
            data-saved-drafts={if(@active_draft, do: "1", else: "0")}
            data-draft-errors={to_string(@draft_errors != %{})}
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Proceeds</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Treasury</h2>
                </Regent.Structure.section_bar>
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
              note={custody_note(@draft_values["treasury_path"])}
              hint={treasury_field().hint}
              value={@draft_values["treasury"]}
              error={@draft_errors["treasury"]}
              autosave
            />
          </form>

          <section
            id="launch-transactions"
            class="launchpad-form-section launchpad-transactions rg-panel rg-panel--surface"
          >
            <header>
              <div>
                <p class="autolaunch-kicker">Wallet review</p>
                <Regent.Structure.section_bar>
                  <h2 class="rg-section-bar__label">Launch transactions</h2>
                </Regent.Structure.section_bar>
              </div>
              <span>{if @launch_ready?, do: "Ready", else: "Details required"}</span>
            </header>
            <p>
              You will see every value and the one transaction before anything is sent. There is
              no launch fee.
            </p>
            <.no_connections
              :if={@launch_ready? && @active_draft && !@has_connections && !@connections_waived}
              typed={@no_connections_typed}
            />
            <.live_component
              :if={@launch_ready? && @active_draft && (@has_connections || @connections_waived)}
              module={AutolaunchWeb.LaunchWalletComponent}
              id={"autolaunch-launch-wallet-#{@active_draft.id}"}
              draft={@active_draft}
              authenticated
              current_human_id={@current_human_id}
              session_lease={@session_lease}
            />
            <Regent.Primitives.button
              :if={!@launch_ready?}
              type="button"
              disabled
            >
              Complete token details and treasury
            </Regent.Primitives.button>
          </section>

          <p
            :if={@draft_notice}
            class={"autolaunch-draft-notice autolaunch-draft-notice--#{@draft_notice.tone}"}
            role={notice_role(@draft_notice.tone)}
          >
            {@draft_notice.message}
          </p>
        </div>

        <aside
          class="launchpad-create__preview rg-panel rg-support-panel"
          aria-label="Live launch preview"
        >
          <div>
            <p class="autolaunch-kicker">Live preview</p>
            <Regent.Structure.section_bar>
              <h2 class="rg-section-bar__label">Your auction</h2>
            </Regent.Structure.section_bar>
          </div>
          <.autolaunch_market_card
            kind={:draft}
            record={Map.put(@draft_values, "preview_metric_unit", @raise_currency)}
            creator_connections={@draft_x_connections}
            preview
          />
          <p>Auctions and launched tokens use this same public identity.</p>
        </aside>
      </section>
    </section>
    """
  end

  # Names the custody choice above the address field so the two read as one
  # decision. Naming a path is not verification of the address.
  defp custody_note(path) when path in [nil, "", "safe", :safe],
    do: "Treasury type: 2-of-3 Safe. Paste the Safe address below."

  defp custody_note(path) when path in ["contract", :contract],
    do: "Treasury type: existing contract or distribution destination. Never verified."

  defp custody_note(path) when path in ["eoa", :eoa],
    do: "Treasury type: single-key EOA. Never verified."

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
        acknowledged?:
          assigns.path in ["eoa", :eoa] and assigns.acknowledgement == @eoa_acknowledgement,
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
      <Regent.Primitives.disclosure
        id={"#{@form_id}-advanced-custody"}
        summary="Advanced, high-risk treasury choices"
        open={@path in ["contract", :contract, "eoa", :eoa]}
      >
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
          class={@acknowledged? && "autolaunch-custody-ack--matched"}
          autocomplete="off"
          aria-invalid={@error && "true"}
          aria-describedby={@described_by}
        >{@acknowledgement}</textarea>
        <p :if={@acknowledged?} class="autolaunch-custody-ack-matched" role="status">
          <span aria-hidden="true">✓</span> Warning typed exactly. Risk acknowledged.
        </p>
        <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">
          {@error}
        </p>
      </Regent.Primitives.disclosure>
    </fieldset>
    """
  end

  attr :typed, :string, default: ""

  # A Revstake launch with no X, GitHub or ENS connected goes ahead only after
  # its creator types (or pastes) the warning below, so they know why it may
  # not be shown.
  defp no_connections(assigns) do
    assigns =
      assign(assigns,
        warning: @no_connections_acknowledgement,
        matched?: String.trim(assigns.typed) == @no_connections_acknowledgement
      )

    ~H"""
    <div id="launch-no-connections" class="no-connections">
      <p>
        You haven't connected X, GitHub or ENS. Connect one above, or launch without them.
      </p>
      <Regent.Primitives.button
        type="button"
        variant="secondary"
        phx-click={JS.dispatch("autolaunch:open-dialog", to: "#launch-no-connections-dialog")}
      >
        Launch without connections
      </Regent.Primitives.button>
      <dialog
        id="launch-no-connections-dialog"
        class="no-connections__dialog"
        aria-labelledby="launch-no-connections-title"
        phx-hook=".OpenDialog"
        phx-mounted={JS.ignore_attributes(["open"])}
      >
        <form class="rg-field" phx-change="no_connections_typed" phx-submit="no_connections_confirmed">
          <h2 id="launch-no-connections-title">Launch without connections</h2>
          <label for="launch-no-connections-typed">Type this sentence exactly to continue:</label>
          <p id="launch-no-connections-warning" class="no-connections__warning">{@warning}</p>
          <textarea
            id="launch-no-connections-typed"
            name="typed"
            rows="4"
            autocomplete="off"
            spellcheck="false"
            aria-describedby="launch-no-connections-warning"
          >{@typed}</textarea>
          <div class="no-connections__actions">
            <Regent.Primitives.button
              type="button"
              variant="secondary"
              phx-click={JS.dispatch("autolaunch:close-dialog", to: "#launch-no-connections-dialog")}
            >
              Cancel
            </Regent.Primitives.button>
            <Regent.Primitives.button type="submit" disabled={!@matched?}>
              Continue
            </Regent.Primitives.button>
          </div>
        </form>
      </dialog>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenDialog">
        export default {
          mounted() {
            this.el.addEventListener("autolaunch:open-dialog", () => this.el.showModal())
            this.el.addEventListener("autolaunch:close-dialog", () => this.el.close())
          }
        }
      </script>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :form_id, :string, required: true
  attr :note, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :autosave, :boolean, default: false
  attr :usd_rate, :any, default: :none, doc: "shows the typed amount in dollars at this rate"

  def draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.field.param}"

    assigns =
      assign(assigns, id: id, described_by: described_by(id, assigns.hint, assigns.error))

    ~H"""
    <Regent.Primitives.field
      id={@id}
      label={@field.label}
      class={[
        "autolaunch-draft-field",
        @field.kind == :long_text && "autolaunch-draft-field--wide"
      ]}
    >
      <textarea
        :if={@field.kind == :long_text}
        id={@id}
        name={"launch_draft[#{@field.param}]"}
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce={@autosave && "400"}
      >{@value}</textarea>
      <p :if={@note} class="autolaunch-draft-note">{@note}</p>
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
      <p
        :if={@usd_rate not in [:none, :test_network]}
        id={"#{@id}-usd"}
        class="autolaunch-draft-hint"
        aria-live="polite"
      >
        <UsdValue.usd amount={@value} rate={@usd_rate} />
      </p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error">{@error}</p>
    </Regent.Primitives.field>
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

  defp token_detail_fields(currency) do
    Enum.map(@token_detail_fields, fn
      %{key: :required_regent_raised} = field -> %{field | label: "Required raise in #{currency}"}
      field -> field
    end)
  end

  defp treasury_field, do: @treasury_field

  defp stage_status(true), do: "Complete"
  defp stage_status(_incomplete), do: "In progress"

  defp described_by(id, hint, error) do
    case Enum.filter([hint && "#{id}-hint", error && "#{id}-error"], &is_binary/1) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  defp notice_role(:error), do: "alert"
  defp notice_role(_tone), do: "status"
end
