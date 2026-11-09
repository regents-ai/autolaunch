defmodule AutolaunchWeb.Live.CreateLive.Templates do
  @moduledoc false
  use AutolaunchWeb, :html

  import AutolaunchWeb.Components.CreateNext
  import AutolaunchWeb.Components.CreateForm
  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1]
  import AutolaunchWeb.Components.ImagePicker

  alias Autolaunch.{Lab, LaunchActions, LaunchDraft}
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.DraftMarks
  alias RegentChain.Address

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
    label: "Treasury address",
    kind: :text,
    hint: nil,
    placeholder: nil,
    optional: false
  }

  @custody_options [
    %{value: "safe", name: "Safe", sub: "2-of-3 Safe on Base", icon: "shield-check"},
    %{
      value: "contract",
      name: "Contract",
      sub: "Existing contract, never checked",
      icon: "file-text"
    },
    %{value: "eoa", name: "Single key", sub: "One private key, highest risk", icon: "key-round"}
  ]

  @terms [
    {"Total supply", "100 billion tokens"},
    {"Sold in the auction", "20% (20 billion tokens)"},
    {"Opening price", "The lowest the auction accepts"},
    {"Minimum raise",
     "About 0.000000001 REGENT, the whole sale at the floor price, so any real bid reaches it. If bids fall short, bidders get their REGENT back."},
    {"Trading pool", "Up to 10% of the tokens, paired with up to half the raise"},
    {"Your treasury",
     "At least half the raise at graduation, and 70% of the tokens, plus unpaired reserve and auction rounding leftovers, over 365 days from graduation"},
    {"Trading fees",
     "2% enters the launch’s revenue splitter; 1% goes to REGENT staking when collected in REGENT, or to the Regent Safe when collected in launch tokens. The 0.30% LP fee is separate"}
  ]

  @stored_params Enum.map(@token_detail_fields, & &1.param) ++
                   ["image", "treasury", "treasury_path", "eoa_acknowledgement"]

  @no_connections_acknowledgement "I realize my Revstake auction may not appear in the gallery or list, because reputation and social proof are important for raising initial funds for an agent"

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  def no_connections_acknowledgement, do: @no_connections_acknowledgement
  def token_detail_params, do: Enum.map(@token_detail_fields, & &1.param)
  def treasury_params, do: ["treasury", "treasury_path", "eoa_acknowledgement"]
  def draft_field_params, do: @stored_params

  @doc """
  Whether the saved treasury step is done. A Safe treasury is done only once
  Base shows it is a 2-of-3 Safe; the local test chain is not read, as its
  launch review does not check the treasury either.
  """
  def treasury_ready?(draft, check) do
    LaunchDraft.treasury_complete?(draft) and
      (draft.treasury_path != :safe or Lab.test_chain?() or safe_found?(draft.treasury, check))
  end

  defp safe_found?(treasury, %{address: address, state: :two_of_three_safe}),
    do: Address.equal?(treasury, address)

  defp safe_found?(_treasury, _check), do: false

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
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :status, :atom, default: :ready
  attr :has_connections, :boolean, default: false
  attr :connections_waived, :boolean, default: false
  attr :no_connections_typed, :string, default: ""
  attr :reviewing?, :boolean, default: false
  attr :launched?, :boolean, default: false
  attr :ticker_taken?, :boolean, default: false
  attr :treasury_check, :map, default: nil
  attr :image_color, :string, default: nil
  attr :creator_connections, :map, default: %{}
  attr :regent_rate, :any, default: nil

  def create(assigns) do
    draft = List.first(assigns.launch_drafts)

    assigns =
      assigns
      |> assign(:active_draft, draft)
      |> assign(
        :launch_ready?,
        draft && LaunchDraft.token_details_complete?(draft) &&
          treasury_ready?(draft, assigns.treasury_check)
      )
      |> assign(:confirm_treasury?, draft && LaunchDraft.treasury_confirmation_needed?(draft))
      |> assign(
        :missing,
        LaunchDraft.missing_token_details(draft || %{}) ++
          if(draft && treasury_ready?(draft, assigns.treasury_check), do: [], else: [:treasury])
      )
      |> assign(:custody, custody(assigns.draft_values["treasury_path"]))
      |> assign(:terms, @terms)
      |> assign(:marks, marks(assigns.draft_errors, assigns.draft_values))
      |> assign(:links_given?, Enum.any?(@link_params, &(assigns.draft_values[&1] != "")))
      |> assign(:opening, LaunchActions.opening())

    ~H"""
    <div :if={@status == :error} class="autolaunch-empty" role="alert">
      <h2>Your draft didn’t open</h2>
      <p>It could not be read just now. Nothing you saved is lost.</p>
      <a href="/agent-business" class="rg-button rg-button--primary">
        <span class="rg-button__label">Try again</span>
      </a>
    </div>

    <div
      :if={@status != :error}
      id="autolaunch-create"
      class="create-page__layout"
    >
      <section class="create-page__form rg-panel rg-panel--surface" aria-label="Your Revstake token">
        <AutolaunchWeb.Components.AgentSetFields.agent_set_fields
          :if={@active_draft}
          draft={@active_draft}
        />
        <fieldset class="create-page__lock" disabled={@reviewing?}>
          <form
            id="launch-token-details"
            class="create-page__fields"
            phx-change="autosave_launch_token_details"
            phx-submit="autosave_launch_token_details"
          >
            <div class="create-page__identity">
              <.image_upload
                upload={@launch_image_upload}
                image={@draft_values["image"]}
                notice={@image_notice}
              />
              <div class="create-page__stack">
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
                <div class="create-menu">
                  <span class="create-page__label">Chain</span>
                  <span class="create-menu__button create-menu__button--fixed">
                    <span class="create-chain create-chain--base" aria-hidden="true"></span>
                    <span class="create-menu__value">Base</span>
                  </span>
                </div>
              </div>
            </div>
            <div class="create-page__folds">
              <.fold id="launch-token-about" icon="file-text" title="Description & website" open>
                <.draft_field
                  field={token_field(:description)}
                  form_id="launch-token-details"
                  value={@draft_values["description"]}
                  error={@marks["description"]}
                />
                <.draft_field
                  field={token_field(:website)}
                  form_id="launch-token-details"
                  value={@draft_values["website"]}
                  error={@marks["website"]}
                />
              </.fold>
              <.fold id="launch-token-links" icon="link" title="Links" open={@links_given?}>
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
              </.fold>
            </div>
          </form>

          <.fold id="launch-socials" icon="user" title="Socials">
            <.live_component
              :if={@current_human_id}
              module={AutolaunchWeb.CreatorConnectionsComponent}
              id="creator-connections"
              current_human_id={@current_human_id}
              session_lease={@session_lease}
              bare
              notify
            />
            <.signed_out_socials :if={!@current_human_id} />
          </.fold>

          <p class="create-page__section">Settings</p>
          <.fold id="launch-treasury" icon="shield-check" title="Treasury" open>
            <form
              id="launch-treasury-details"
              class="create-page__fields"
              phx-change="autosave_launch_treasury"
              phx-submit="autosave_launch_treasury"
            >
              <.custody_menu form_id="launch-treasury-details" path={@custody} />
              <.draft_field
                field={treasury_field()}
                form_id="launch-treasury-details"
                value={@draft_values["treasury"]}
                error={@marks["treasury"]}
              >
                <p
                  id="launch-treasury-details-check"
                  class="create-page__hint create-page__check"
                  role="status"
                >
                  {safe_line(@treasury_check)}
                </p>
              </.draft_field>
              <.eoa_warning
                :if={@custody.value == "eoa"}
                form_id="launch-treasury-details"
                acknowledgement={@draft_values["eoa_acknowledgement"]}
                error={@draft_errors["eoa_acknowledgement"]}
              />
            </form>
          </.fold>
        </fieldset>
      </section>

      <aside id="create-preview" class="create-page__side" aria-label="Your launch">
        <.summary_card
          id="revstake-summary"
          name={@draft_values["name"]}
          symbol={@draft_values["symbol"]}
          image={@draft_values["image"]}
          color={@image_color}
          pair="REGENT"
          chain={:base}
          sold="20%"
          connections={@creator_connections}
          terms={@terms}
        >
          <:row label="Opening price">
            <MarketCard.price_figure
              amount={@opening.price}
              unit="REGENT"
              rate={regent_rate(@regent_rate)}
            />
          </:row>
          <:row label="FDV">
            {MarketCard.money(@opening.fdv, regent_rate(@regent_rate), "REGENT")}
          </:row>
          <:row label="Raises in">REGENT</:row>
          <:row label="Treasury">{@custody.name}</:row>
        </.summary_card>

        <div id="launch-transactions" class="create-page__launch">
          <p :if={@launches_paused?} class="create-page__notice" role="status">
            New launches are paused until the new version opens.
          </p>
          <.agent_treasury
            :if={@launch_ready? && !@reviewing? && @confirm_treasury?}
            treasury={@active_draft.treasury}
          />
          <.no_connections
            :if={@launch_ready? && !@confirm_treasury? && !@has_connections && !@connections_waived}
            typed={@no_connections_typed}
          />
          <.live_component
            :if={
              @active_draft &&
                (@launched? ||
                   (((@launch_ready? && !@confirm_treasury?) || @reviewing?) &&
                      (@has_connections || @connections_waived)))
            }
            module={AutolaunchWeb.LaunchWalletComponent}
            id={"autolaunch-launch-wallet-#{@active_draft.id}"}
            draft={@active_draft}
            authenticated
            launches_paused?={@launches_paused?}
            listings={@listings}
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />
          <%= if @current_human_id && !@launch_ready? && !@reviewing? && !@launched? do %>
            <Regent.Primitives.button type="button" class="create-page__launch-button" disabled>
              Review launch
            </Regent.Primitives.button>
            <p class="create-page__need">Still needed: {DraftMarks.still_needed(@missing)}</p>
          <% end %>
          <Regent.Primitives.button
            :if={!@current_human_id}
            type="button"
            class="create-page__launch-button"
            data-account-target="sign-in"
          >
            Sign in to save and launch
          </Regent.Primitives.button>
          <p
            :if={@draft_notice}
            class={"create-page__notice create-page__notice--#{@draft_notice.tone}"}
            role={notice_role(@draft_notice.tone)}
          >
            {@draft_notice.message}
          </p>
        </div>
      </aside>
    </div>

    <section :if={@status != :error} class="create-page__info" aria-labelledby="create-info-title">
      <h2 id="create-info-title" class="create-page__info-title">
        Details
      </h2>
      <.launch_plan
        id="revstake-plan"
        kind={:revstake}
        ticker={present_ticker(@draft_values["symbol"])}
        minimum="About 0.000000001 REGENT, the whole sale at the floor price, so any real bid reaches it"
        chosen={[
          {"Treasury", present(@draft_values["treasury"], "Not set yet")}
        ]}
      />
    </section>
    <.draft_carry_over
      id="launch-carry-over"
      key="autolaunch:create:revstake"
      signed_in={@current_human_id != nil}
    />
    """
  end

  # REGENT's dollar price once it has been read; on a test network, and until
  # then, the card's figures stay in REGENT.
  defp regent_rate(%{ok?: true, result: %Decimal{} = rate}), do: rate
  defp regent_rate(_unread), do: nil

  # What Base shows at the Safe address, once it has answered.
  defp safe_line(%{state: :two_of_three_safe}), do: "2-of-3 Safe found"
  defp safe_line(%{state: :wallet}), do: "This is a wallet, not a Safe"
  defp safe_line(%{state: :no_safe}), do: "No Safe at this address"
  defp safe_line(%{state: :other_safe}), do: "Safe, but not 2 of 3"
  defp safe_line(%{state: :unread}), do: "Base could not be read just now"
  defp safe_line(_nothing_yet), do: nil

  # The chosen treasury type; a draft that names none yet is a Safe.
  defp custody(path) do
    value = if path in [nil, ""], do: "safe", else: to_string(path)
    Enum.find(@custody_options, &(&1.value == value))
  end

  attr :form_id, :string, required: true
  attr :path, :map, required: true, doc: "the chosen treasury type"

  defp custody_menu(assigns) do
    assigns = assign(assigns, :options, @custody_options)

    ~H"""
    <.menu id={"#{@form_id}-custody"} label="Treasury type">
      <:current>
        <span class="create-menu__icon"><Regent.Icons.icon name={@path.icon} /></span>
        <span class="create-menu__value">{@path.name}<small>{@path.sub}</small></span>
      </:current>
      <label :for={option <- @options} class="create-menu__option">
        <input
          type="radio"
          name="launch_draft[treasury_path]"
          value={option.value}
          checked={option.value == @path.value}
          class="visually-hidden"
        />
        <span class="create-menu__icon"><Regent.Icons.icon name={option.icon} /></span>
        <span class="create-menu__name">{option.name}</span>
        <span class="create-menu__sub">{option.sub}</span>
        <Regent.Icons.icon name="check" class="create-menu__check" />
      </label>
    </.menu>
    <a
      :if={@path.value == "safe"}
      href="https://app.safe.global/new-safe/create?chain=base"
      class="standalone-link"
      target="_blank"
      rel="noopener noreferrer"
    >
      Create a Safe
    </a>
    """
  end

  attr :form_id, :string, required: true
  attr :acknowledgement, :string, default: ""
  attr :error, :string, default: nil

  # A single-key treasury goes ahead only once its creator types the warning
  # character for character.
  defp eoa_warning(assigns) do
    id = "#{assigns.form_id}-eoa-acknowledgement"

    assigns =
      assign(assigns,
        id: id,
        warning_copy: @eoa_acknowledgement,
        acknowledged?: assigns.acknowledgement == @eoa_acknowledgement,
        described_by:
          Enum.join(Enum.filter(["#{id}-warning", assigns.error && "#{id}-error"], & &1), " ")
      )

    ~H"""
    <div class="rg-field create-field autolaunch-custody-eoa">
      <label for={@id}>Warning</label>
      <p class="create-page__hint">Type this exactly to use a single key.</p>
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
        <Regent.Icons.icon name="check" /> Warning typed exactly. Risk acknowledged.
      </p>
      <p
        :if={@error}
        id={"#{@id}-error"}
        class="autolaunch-draft-error"
        role="alert"
        phx-hook="MotionRefusal"
        data-refused
      >
        {@error}
      </p>
    </div>
    """
  end

  attr :treasury, :string, required: true

  # A Safe or smart contract account the creator's paired agent chose as the
  # treasury goes ahead only once the creator ticks that it receives the
  # treasury funds (`Autolaunch.LaunchDraft.treasury_confirmation_needed?/1`).
  defp agent_treasury(assigns) do
    ~H"""
    <form id="launch-agent-treasury" class="agent-treasury" phx-change="confirm_agent_treasury">
      <p class="agent-treasury__address">{@treasury}</p>
      <input type="hidden" name="treasury" value={@treasury} />
      <%!-- Keyed by the address, so a new treasury always starts unticked. --%>
      <label
        id={"launch-agent-treasury-#{String.downcase(@treasury)}"}
        class="agent-treasury__confirm"
      >
        <input type="checkbox" name="confirmed" value="true" />
        This smart contract will receive all treasury funds
      </label>
    </form>
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
        You haven't connected X, GitHub or ENS. Connect one under Socials, or launch without them.
      </p>
      <Regent.Primitives.button
        type="button"
        variant="secondary"
        phx-click={JS.dispatch("autolaunch:open-dialog", to: "#launch-no-connections-dialog")}
      >
        Skip connections
      </Regent.Primitives.button>
      <dialog
        id="launch-no-connections-dialog"
        class="no-connections__dialog"
        aria-labelledby="launch-no-connections-title"
        {AutolaunchWeb.Motion.panel("sheet", ["open"])}
      >
        <form
          id="launch-no-connections-form"
          class="rg-field"
          phx-change="no_connections_typed"
          phx-submit="no_connections_confirmed"
        >
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
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :warning, :string, default: nil
  slot :inner_block

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
      {render_slot(@inner_block)}
      <p :if={@field.hint} id={"#{@id}-hint"} class="create-page__hint">{@field.hint}</p>
      <p :if={@warning} id={"#{@id}-warning"} class="create-page__hint" role="status">{@warning}</p>
      <p
        :if={@error}
        id={"#{@id}-error"}
        class="autolaunch-draft-error"
        role="alert"
        phx-hook="MotionRefusal"
        data-refused
      >
        {@error}
      </p>
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
