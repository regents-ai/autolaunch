defmodule AutolaunchWeb.Live.CreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.CreateNext
  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1]
  import AutolaunchWeb.Components.ImagePicker

  alias Autolaunch.LaunchDraft
  alias AutolaunchWeb.DraftMarks

  @address_hint "0x followed by exactly 40 hexadecimal characters."

  @token_detail_fields [
                         %{key: :name, param: "name", label: "Name", kind: :text},
                         %{key: :symbol, param: "symbol", label: "Ticker", kind: :text},
                         %{
                           key: :description,
                           param: "description",
                           label: "Description",
                           kind: :long_text
                         },
                         %{
                           key: :website,
                           param: "website",
                           label: "Website",
                           placeholder: "https://",
                           optional: true
                         },
                         %{
                           key: :telegram,
                           param: "telegram",
                           label: "Telegram",
                           placeholder: "https://t.me/yourgroup",
                           optional: true
                         },
                         %{
                           key: :discord,
                           param: "discord",
                           label: "Discord",
                           placeholder: "https://discord.gg/invite",
                           optional: true
                         },
                         %{
                           key: :other_link_1,
                           param: "other_link_1",
                           label: "Other link",
                           placeholder: "https://",
                           optional: true
                         },
                         %{
                           key: :other_link_2,
                           param: "other_link_2",
                           label: "Other link",
                           placeholder: "https://",
                           optional: true
                         },
                         %{
                           key: :other_link_3,
                           param: "other_link_3",
                           label: "Other link",
                           placeholder: "https://",
                           optional: true
                         }
                       ]
                       |> Enum.map(
                         &Map.merge(
                           %{kind: :text, hint: nil, placeholder: nil, optional: false},
                           &1
                         )
                       )

  @link_params ~w(telegram discord other_link_1 other_link_2 other_link_3)

  @treasury_field %{
    key: :treasury,
    param: "treasury",
    label: "Immutable treasury recipient",
    kind: :text,
    hint: @address_hint,
    placeholder: nil,
    optional: false
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
  attr :image_notice, :string, default: nil
  attr :launch_image_upload, :map, default: nil
  attr :auction_limit_reached, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :status, :atom, default: :ready
  attr :has_connections, :boolean, default: false
  attr :connections_waived, :boolean, default: false
  attr :no_connections_typed, :string, default: ""
  attr :reviewing?, :boolean, default: false
  attr :ticker_taken?, :boolean, default: false

  def create(assigns) do
    draft = List.first(assigns.launch_drafts)

    assigns =
      assigns
      |> assign(:active_draft, draft)
      |> assign(:launch_ready?, draft && LaunchDraft.launch_ready?(draft))
      |> assign(:marks, marks(assigns.draft_errors, assigns.draft_values))
      |> assign(:links_given?, Enum.any?(@link_params, &(assigns.draft_values[&1] != "")))

    ~H"""
    <p :if={@auction_limit_reached} class="launchpad-limit" role="status">
      You already have an auction. One auction per account for now.
    </p>
    <p :if={@status == :error} class="autolaunch-empty">
      Your draft could not be loaded. Refresh and try again.
    </p>

    <div
      :if={@status != :error}
      id="autolaunch-create"
      class="create-page__layout"
      data-agent-tools="autolaunch_launch_form autolaunch_fill_revstake"
      phx-hook="AgentTools"
    >
      <section class="create-page__form rg-panel rg-panel--surface" aria-label="Your Revstake token">
        <.live_component
          :if={@current_human_id}
          module={AutolaunchWeb.CreatorConnectionsComponent}
          id="creator-connections"
          current_human_id={@current_human_id}
          session_lease={@session_lease}
          notify
        />
        <div :if={!@current_human_id} id="creator-connections" class="create-page__fields">
          <span class="create-page__label">Creator connections</span>
          <p class="create-page__hint">
            After you sign in, connect X, GitHub or ENS to build trust with bidders.
          </p>
        </div>

        <fieldset class="create-page__lock" disabled={@reviewing?}>
          <form
            id="launch-token-details"
            class="create-page__fields"
            phx-change="autosave_launch_token_details"
            phx-submit="autosave_launch_token_details"
          >
            <div class="create-page__pair">
              <.draft_field
                field={token_field(:name)}
                form_id="launch-token-details"
                value={@draft_values["name"]}
                error={@marks["name"]}
              />
              <.draft_field
                field={token_field(:symbol)}
                form_id="launch-token-details"
                value={@draft_values["symbol"]}
                error={@marks["symbol"]}
                warning={@ticker_taken? && "Another launch already uses this ticker."}
              />
            </div>
            <.draft_field
              field={token_field(:description)}
              form_id="launch-token-details"
              value={@draft_values["description"]}
              error={@marks["description"]}
            />
            <.image_upload
              upload={@launch_image_upload}
              image={@draft_values["image"]}
              notice={@image_notice}
            />
            <.draft_field
              field={token_field(:website)}
              form_id="launch-token-details"
              value={@draft_values["website"]}
              error={@marks["website"]}
            />
            <Regent.Primitives.disclosure
              id="launch-token-links"
              summary="More links"
              class="create-page__more"
              open={@links_given?}
              phx-mounted={JS.ignore_attributes(["open"])}
            >
              <div class="create-page__pair">
                <.draft_field
                  :for={key <- [:telegram, :discord]}
                  field={token_field(key)}
                  form_id="launch-token-details"
                  value={@draft_values[Atom.to_string(key)]}
                  error={@marks[Atom.to_string(key)]}
                />
              </div>
              <.draft_field
                :for={key <- [:other_link_1, :other_link_2, :other_link_3]}
                field={token_field(key)}
                form_id="launch-token-details"
                value={@draft_values[Atom.to_string(key)]}
                error={@marks[Atom.to_string(key)]}
              />
            </Regent.Primitives.disclosure>
          </form>

          <form
            id="launch-treasury-details"
            class="create-page__fields"
            phx-change="autosave_launch_treasury"
            phx-submit="autosave_launch_treasury"
          >
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
              value={@draft_values["treasury"]}
              error={@marks["treasury"]}
            />
          </form>
        </fieldset>

        <div id="launch-transactions" class="create-page__launch">
          <p class="create-page__hint">
            You will see every value and the one transaction before anything is sent.
          </p>
          <.no_connections
            :if={@launch_ready? && @active_draft && !@has_connections && !@connections_waived}
            typed={@no_connections_typed}
          />
          <.live_component
            :if={
              (@launch_ready? || @reviewing?) && @active_draft &&
                (@has_connections || @connections_waived)
            }
            module={AutolaunchWeb.LaunchWalletComponent}
            id={"autolaunch-launch-wallet-#{@active_draft.id}"}
            draft={@active_draft}
            authenticated
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />
          <Regent.Primitives.button
            :if={@current_human_id && !@launch_ready? && !@reviewing?}
            type="button"
            class="create-page__launch-button"
            disabled
          >
            Complete token details and treasury
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :if={!@current_human_id}
            type="button"
            class="create-page__launch-button"
            data-account-target="sign-in"
          >
            Sign in to save and launch
          </Regent.Primitives.button>
          <p :if={!@current_human_id} class="create-page__hint">
            Nothing is saved until you sign in. What you have entered comes with you.
          </p>
          <p
            :if={@draft_notice}
            class={"create-page__notice create-page__notice--#{@draft_notice.tone}"}
            role={notice_role(@draft_notice.tone)}
          >
            {@draft_notice.message}
          </p>
        </div>
      </section>

      <aside
        class="create-page__summary create-page__summary--next rg-panel rg-panel--surface"
        aria-label="Your token"
      >
        <p class="autolaunch-kicker">Your token</p>
        <div class="create-token">
          <img
            :if={@draft_values["image"] != ""}
            src={@draft_values["image"]}
            alt=""
            class="create-token__image"
          />
          <span :if={@draft_values["image"] == ""} class="create-token__image" aria-hidden="true"></span>
          <div class="create-token__names">
            <strong>{present(@draft_values["name"], "Your token")}</strong>
            <span>${present(@draft_values["symbol"], "TICKER")}</span>
          </div>
        </div>
        <.launch_plan
          id="revstake-plan"
          kind={:revstake}
          ticker={present_ticker(@draft_values["symbol"])}
          minimum="Less than one REGENT, so any real bid is enough"
          chosen={[
            {"Treasury", present(@draft_values["treasury"], "Not set yet")}
          ]}
        />
        <Regent.Primitives.disclosure
          id="launch-terms"
          summary="Every term"
          class="create-page__more"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <table class="stocks-terms-table">
            <tbody>
              <tr>
                <th scope="row">Total supply</th>
                <td>100 billion tokens</td>
              </tr>
              <tr>
                <th scope="row">Sold in the auction</th>
                <td>20% (20 billion tokens)</td>
              </tr>
              <tr>
                <th scope="row">Opening price</th>
                <td>The lowest the auction accepts</td>
              </tr>
              <tr>
                <th scope="row">Minimum raise</th>
                <td>
                  Less than one REGENT, so any real bid is enough
                  <br />If bids fall short, bidders get their REGENT back.
                </td>
              </tr>
              <tr>
                <th scope="row">Trading pool</th>
                <td>Up to 10% of the tokens, paired with up to half the raise</td>
              </tr>
              <tr>
                <th scope="row">Your treasury</th>
                <td>
                  At least half the raise at once, and 70% of the tokens, plus any the pool did
                  not take, over a year
                </td>
              </tr>
              <tr>
                <th scope="row">Trading fees</th>
                <td>2% to stakers and 1% to Regent, plus the 0.30% pool fee</td>
              </tr>
            </tbody>
          </table>
        </Regent.Primitives.disclosure>
      </aside>
    </div>
    <.draft_carry_over
      id="launch-carry-over"
      key="autolaunch:create:revstake"
      signed_in={@current_human_id != nil}
    />
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
        phx-mounted={JS.ignore_attributes(["open"])}
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
        {AutolaunchWeb.Motion.panel("dialog", ["open"])}
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
    </div>
    """
  end

  attr :field, :map, required: true
  attr :form_id, :string, required: true
  attr :note, :string, default: nil
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :warning, :string, default: nil

  def draft_field(assigns) do
    id = "#{assigns.form_id}-#{assigns.field.param}"

    assigns =
      assign(assigns,
        id: id,
        described_by: described_by(id, [assigns.field.hint, assigns.warning, assigns.error])
      )

    ~H"""
    <div class="rg-field create-field">
      <label for={@id}>
        {@field.label}
        <span :if={@field.optional} class="create-field__optional">optional</span>
      </label>
      <p :if={@note} class="create-page__hint">{@note}</p>
      <textarea
        :if={@field.kind == :long_text}
        id={@id}
        name={"launch_draft[#{@field.param}]"}
        rows="3"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      >{@value}</textarea>
      <input
        :if={@field.kind == :text}
        type="text"
        id={@id}
        name={"launch_draft[#{@field.param}]"}
        value={@value}
        placeholder={@field.placeholder}
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@described_by}
        phx-debounce="400"
      />
      <p :if={@field.hint} id={"#{@id}-hint"} class="create-page__hint">{@field.hint}</p>
      <p :if={@warning} id={"#{@id}-warning"} class="create-page__hint" role="status">{@warning}</p>
      <p :if={@error} id={"#{@id}-error"} class="autolaunch-draft-error" role="alert">{@error}</p>
    </div>
    """
  end

  defp token_field(key), do: Enum.find(@token_detail_fields, &(&1.key == key))

  defp present(value, placeholder) do
    case String.trim(value) do
      "" -> placeholder
      value -> value
    end
  end

  # Until the creator names a symbol, the supply is counted in plain tokens.
  defp present_ticker(symbol), do: present(symbol, "tokens")

  defp treasury_field, do: @treasury_field

  defp described_by(id, [hint, warning, error]) do
    case Enum.filter(
           [hint && "#{id}-hint", warning && "#{id}-warning", error && "#{id}-error"],
           &is_binary/1
         ) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  # Beside the saved-as-typed marks both create pages share, a treasury that
  # is not yet a whole address says so.
  defp marks(errors, values) do
    marks = DraftMarks.marked(errors, values)
    treasury = values["treasury"]

    if treasury in [nil, ""] or LaunchDraft.treasury_address?(treasury),
      do: marks,
      else:
        Map.put_new(
          marks,
          "treasury",
          "Not a whole address yet. Copy it from your wallet or Safe."
        )
  end

  defp notice_role(:error), do: "alert"
  defp notice_role(_tone), do: "status"
end
