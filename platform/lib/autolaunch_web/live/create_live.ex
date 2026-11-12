defmodule AutolaunchWeb.CreateLive do
  @moduledoc """
  Create a Revstake token, at /agent-business: the Revstake launch form on
  Base. Memestock launches have their own page at /create.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.
  """

  use AutolaunchWeb, :live_view

  require Logger

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human

  alias Autolaunch.{
    AgentDrafts,
    ImageColor,
    Lab,
    LaunchActions,
    LaunchDraft,
    LaunchDraftImageStorage,
    Listings,
    Ticker,
    TreasurySecurity
  }

  alias AutolaunchWeb.Components.{AutolaunchHelpers, MarketCard}
  alias AutolaunchWeb.{CreatorConnectionsComponent, DraftMarks, UsdValue}
  alias AutolaunchWeb.Live.Session
  alias RegentChain.Address

  import AutolaunchWeb.Components.CreateForm
  import AutolaunchWeb.Components.CreateNext
  import AutolaunchWeb.Components.DraftCarryOver, only: [draft_carry_over: 1, keep_draft: 2]
  import AutolaunchWeb.Components.ImagePicker
  import AutolaunchWeb.Components.LaunchKindChoice

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
     "2% goes to the token’s staking; 1% goes to REGENT staking when collected in REGENT, or to the Regent Safe when collected in launch tokens. The 0.30% pool fee is separate"}
  ]

  @sections %{
    "autosave_launch_token_details" => Enum.map(@token_detail_fields, & &1.param),
    "autosave_launch_treasury" => ~w(treasury treasury_path eoa_acknowledgement)
  }

  @stored_params Enum.map(@token_detail_fields, & &1.param) ++
                   ["image", "treasury", "treasury_path", "eoa_acknowledgement"]

  @no_connections_acknowledgement "I realize my Revstake auction may not appear in the gallery or list, because reputation and social proof are important for raising initial funds for an agent"

  @eoa_acknowledgement "This auction will be owned by my EOA private key, and significant harm and token value will happen if it is lost or compromised. I was warned to create a Gnosis Safe or 0xSplits smart account as the owner, and I realize auction bidders and token owners will see that it is EOA-owned and more risky. I accept these problems, and wish to continue with EOA ownership of the token."

  @autosave_events ["autosave_launch_token_details", "autosave_launch_treasury"]
  @actions %{
    "autosave_launch_token_details" => :autosave_token_details,
    "autosave_launch_treasury" => :autosave_treasury
  }

  # A completed sign-in reloads the same document, so a signed-out visitor
  # returns here, now with their account's draft, without any redirect
  # parameter to validate.
  def mount(_params, _session, socket) do
    actor = human_actor(socket)

    socket =
      socket
      |> assign(AutolaunchWeb.PublicDocuments.page("/agent-business"))
      |> assign_defaults(actor)
      |> UsdValue.assign_rate(:regent_rate, :base, fn ->
        {:ok, %{regent_rate: UsdValue.rate(%{kind: :agent})}}
      end)
      |> read_launches_paused()

    case actor do
      nil ->
        {:ok, assign_sketch(socket, %LaunchDraft{})}

      actor ->
        socket =
          allow_upload(socket, :launch_image,
            accept: ~w(.png .jpg .jpeg .webp),
            max_entries: 1,
            max_file_size: 2_097_152,
            auto_upload: true,
            progress: &handle_launch_image_progress/3
          )

        {:ok,
         if connected?(socket) do
           Listings.subscribe()
           AgentDrafts.subscribe("revstake", actor.human_account_id)

           socket
           |> load_create(actor)
           |> assign_ticker_taken()
         else
           socket
         end}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh_x_connections", _params, %{assigns: %{current_human_id: id}} = socket)
      when is_integer(id) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "creator-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, assign_connections(socket)}
  end

  # Signed out there is no socials panel to refresh.
  def handle_event("refresh_x_connections", _params, socket), do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @autosave_events do
    values = Map.take(params["launch_draft"] || %{}, Map.fetch!(@sections, event))
    {:noreply, autosaved(socket, event, values)}
  end

  # What a visitor typed while signed out, handed back by this tab. Signed in,
  # it goes into the account's draft through the same saves as typing it
  # would; signed out, it refills the unsaved form after a reload. A draft
  # that could not be read takes nothing, and the tab keeps the values.
  def handle_event("restore_draft", %{"values" => values}, socket) when is_map(values) do
    if socket.assigns.status == :error,
      do: {:reply, %{taken: false}, socket},
      else: {:reply, %{taken: true}, restore(socket, values)}
  end

  # The person ticked that the smart contract account their agent chose is
  # where the launch's money goes. One the agent changed since this page
  # showed it is not confirmed; the page shows the new one to check instead.
  # The tick is written under the page's lease read again now, so a page whose
  # sign-in could not be read, or has ended, confirms nothing.
  def handle_event(
        "confirm_agent_treasury",
        %{"treasury" => treasury, "confirmed" => "true"},
        socket
      )
      when is_binary(treasury) do
    actor = human_actor(socket)

    with {:ok, _confirmed} <-
           Session.transact(socket, fn -> confirm_treasury(actor, treasury) end),
         {:ok, draft} <- reload_draft(actor) do
      {:noreply, assign_loaded_draft(socket, draft, actor)}
    else
      _refused ->
        socket =
          case reload_draft(actor) do
            {:ok, draft} -> assign_loaded_draft(socket, draft, actor)
            {:error, _error} -> socket
          end

        {:noreply,
         assign(socket,
           draft_notice: %{
             tone: :error,
             message: "The treasury could not be confirmed. Check it and tick again."
           }
         )}
    end
  end

  def handle_event("confirm_agent_treasury", _params, socket), do: {:noreply, socket}

  def handle_event("no_connections_typed", %{"typed" => typed}, socket) when is_binary(typed),
    do: {:noreply, assign(socket, no_connections_typed: typed)}

  def handle_event("no_connections_confirmed", %{"typed" => typed}, socket)
      when is_binary(typed) do
    {:noreply,
     assign(socket,
       no_connections_typed: typed,
       connections_waived: String.trim(typed) == @no_connections_acknowledgement
     )}
  end

  def render(assigns) do
    draft = List.first(assigns.launch_drafts)
    treasury_done? = draft && treasury_ready?(draft, assigns.treasury_check)

    assigns =
      assign(assigns,
        launch_image_upload: assigns[:uploads][:launch_image],
        active_draft: draft,
        launch_ready?: draft && LaunchDraft.token_details_complete?(draft) && treasury_done?,
        confirm_treasury?: draft && LaunchDraft.treasury_confirmation_needed?(draft),
        missing:
          LaunchDraft.missing_token_details(draft || %{}) ++
            if(treasury_done?, do: [], else: [:treasury]),
        custody: custody(assigns.draft_values["treasury_path"]),
        terms: @terms,
        marks: marks(assigns.draft_errors, assigns.draft_values),
        links_given?: Enum.any?(@link_params, &(assigns.draft_values[&1] != "")),
        opening: LaunchActions.opening()
      )

    ~H"""
    <div class="create-page">
      <header class="create-page__header">
        <h1>Create Revstake</h1>
        <.launch_kind_choice current={:revstake} />
      </header>
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
              role={if @draft_notice.tone == :error, do: "alert", else: "status"}
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
    </div>
    """
  end

  # A launch card opened its review: the details lock so the review always
  # matches them, and a saved-draft note no longer describes what this page is
  # doing and comes down. Once the review closes they open again, read anew,
  # blank when the launch was listed. A launch just made keeps its card, which
  # says so, until the person dismisses it.
  def handle_info({:launch_review, :open}, socket),
    do: {:noreply, assign(socket, reviewing?: true, draft_notice: nil)}

  def handle_info({:launch_review, news}, socket) when news in [:closed, :launched] do
    socket =
      socket
      |> assign(reviewing?: false, launched?: news == :launched)
      |> waiver_after(news)

    case human_actor(socket) do
      nil -> {:noreply, socket}
      actor -> {:noreply, socket |> load_create(actor) |> assign_ticker_taken()}
    end
  end

  # Something new is listed: a launch card still looking for the auction page
  # of a launch made here looks again (`AutolaunchWeb.LaunchSteps.relisted/2`).
  def handle_info({:autolaunch_listings_changed, _auction_id}, socket),
    do: {:noreply, update(socket, :listings, &(&1 + 1))}

  def handle_info({:creator_connections, :changed}, socket),
    do: {:noreply, assign_connections(socket)}

  # The person's paired agent saved this draft: the form and the list of what
  # the agent filled in show it, and what the person typed that could not be
  # saved stays in its box with its mark. During a review the details stay
  # locked; they are read anew when it closes.
  def handle_info({:agent_draft_saved, "revstake"}, %{assigns: %{reviewing?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:agent_draft_saved, "revstake"}, socket) do
    actor = human_actor(socket)
    unsaved = Map.take(socket.assigns.draft_values, Map.keys(socket.assigns.draft_errors))

    case reload_draft(actor) do
      {:ok, draft} ->
        socket = assign_loaded_draft(socket, draft, actor)

        {:noreply,
         socket
         |> assign(draft_values: Map.merge(socket.assigns.draft_values, unsaved))
         |> assign_ticker_taken()
         |> check_treasury()}

      {:error, _error} ->
        {:noreply, socket}
    end
  end

  def handle_async(:treasury_check, result, socket),
    do: {:noreply, assign(socket, treasury_check: checked(socket.assigns.treasury_check, result))}

  def handle_async(:launches_paused, {:ok, {:ok, paused}}, socket),
    do: {:noreply, assign(socket, launches_paused?: paused)}

  def handle_async(:launches_paused, _unread, socket), do: {:noreply, socket}

  # The typed "no connections" waiver belongs to the launch it was typed for: a
  # launch made starts the next one without it.
  defp waiver_after(socket, :launched),
    do: assign(socket, connections_waived: false, no_connections_typed: "")

  defp waiver_after(socket, :closed), do: socket

  # One section of the form saved as typing it would save it.
  defp autosaved(socket, event, values) do
    socket =
      case save_section(socket, event, values) do
        {:ok, socket} ->
          assign(socket, draft_errors: %{}, draft_notice: saved_notice(socket))

        {:error, errors} ->
          assign(socket,
            draft_values: Map.merge(socket.assigns.draft_values, values),
            draft_errors: errors,
            draft_notice: unsaved_notice(socket, errors)
          )
      end

    socket |> assign_ticker_taken() |> check_treasury() |> keep()
  end

  # One section of the form, saved to the account's draft or, signed out,
  # applied to the unsaved one under the same rules.
  defp save_section(socket, event, values) do
    case human_actor(socket) do
      nil ->
        case sketch(socket.assigns.sketch, Map.fetch!(@actions, event), values) do
          {:ok, sketch} -> {:ok, assign_sketch(socket, sketch)}
          error -> {:error, draft_field_errors(error)}
        end

      actor ->
        with {:ok, _saved} <-
               save_draft(socket, actor, &autosave_draft(event, &1, values, actor)),
             {:ok, reloaded} <- reload_draft(actor) do
          {:ok, assign_loaded_draft(socket, reloaded, actor)}
        else
          error -> {:error, draft_field_errors(error)}
        end
    end
  end

  defp saved_notice(%{assigns: %{current_human_id: nil}}), do: nil
  defp saved_notice(_socket), do: %{tone: :success, message: "Saved to your account."}

  defp unsaved_notice(%{assigns: %{current_human_id: nil}}, _errors), do: nil

  # A save refused for a field marks that field; one that failed for any other
  # reason marks nothing, so the note says to try again instead.
  defp unsaved_notice(_socket, errors) when errors == %{},
    do: %{
      tone: :error,
      message: "That change could not be saved just now. Try again in a moment."
    }

  defp unsaved_notice(_socket, _errors),
    do: %{tone: :error, message: "That change could not be saved. Check the marked field."}

  defp restore(socket, values) do
    values = Map.filter(values, fn {_param, value} -> is_binary(value) end)

    {socket, unsaved, errors} =
      Enum.reduce(@autosave_events, {socket, %{}, %{}}, &restore_section(&1, &2, values))

    socket
    |> assign(
      draft_values: Map.merge(socket.assigns.draft_values, unsaved),
      draft_errors: errors,
      draft_notice:
        if(unsaved == %{}, do: saved_notice(socket), else: unsaved_notice(socket, errors))
    )
    |> assign_ticker_taken()
    |> check_treasury()
  end

  # A section that cannot be saved stays on the form as typed, marked.
  defp restore_section(event, {socket, unsaved, errors} = restored, values) do
    case Map.take(values, Map.fetch!(@sections, event)) do
      section when map_size(section) == 0 ->
        restored

      section ->
        case save_section(socket, event, section) do
          {:ok, socket} -> {socket, unsaved, errors}
          {:error, marked} -> {socket, Map.merge(unsaved, section), Map.merge(errors, marked)}
        end
    end
  end

  # Signed out, this tab keeps whatever differs from a new draft.
  defp keep(%{assigns: %{current_human_id: nil}} = socket) do
    fresh = draft_values(%LaunchDraft{})

    keep_draft(
      socket,
      Map.reject(socket.assigns.draft_values, fn {param, value} -> fresh[param] == value end)
    )
  end

  defp keep(socket), do: socket

  defp sketch(draft, action, values) do
    case draft |> Ash.Changeset.for_update(action, values) |> Ash.Changeset.apply_attributes() do
      {:ok, sketch} -> {:ok, sketch}
      {:error, changeset} -> {:error, Ash.Error.to_error_class(changeset.errors)}
    end
  end

  defp assign_sketch(socket, sketch),
    do: assign(socket, sketch: sketch, draft_values: draft_values(sketch), status: :ready)

  defp autosave_draft("autosave_launch_token_details", draft, values, actor),
    do: Autolaunch.autosave_launch_token_details(draft, values, actor: actor)

  defp autosave_draft("autosave_launch_treasury", draft, values, actor),
    do: Autolaunch.autosave_launch_treasury(draft, values, actor: actor)

  defp handle_launch_image_progress(:launch_image, entry, socket) do
    if entry.done?,
      do: finish_launch_image(entry, socket),
      else: {:noreply, socket}
  end

  # Phoenix supplies the completed-upload temp path; it is never accepted from
  # request parameters or other user-controlled path input.
  # sobelow_skip ["Traversal.FileModule"]
  defp finish_launch_image(entry, socket) do
    with bytes when is_binary(bytes) <-
           consume_uploaded_entry(socket, entry, fn %{path: path} -> File.read(path) end),
         %Human{} = actor <- human_actor(socket),
         {:ok, stored} <- attach_image(socket, actor, bytes, entry) do
      {:noreply, assign_saved_image(socket, stored, actor)}
    else
      {:error, :image_changed} ->
        {:noreply,
         assign(socket,
           image_notice:
             "The saved image changed while this one was uploading. Your newer image was kept; choose again to replace it."
         )}

      {:error, :too_many_pixels} ->
        {:noreply,
         assign(socket,
           image_notice: "That picture is too big. Choose one no larger than 4096 by 4096 pixels."
         )}

      # Upload progress reaches the page without its event recheck, so the
      # save's own lease check (`Session.transact/2`) answers for it: a lost
      # connection is a try-again, and an ended sign-in lapses the page.
      {:error, :sign_in_unread} ->
        {:noreply,
         assign(socket, image_notice: "That did not go through. Try again in a moment.")}

      {:error, ended} when ended in [:stale_authority, :session_lease_required] ->
        {:noreply, Session.lapse(socket)}

      _error ->
        {:noreply,
         assign(socket,
           image_notice: "That file is not a complete PNG, JPEG, or WebP image under 2 MB."
         )}
    end
  end

  defp assign_saved_image(socket, stored, actor) do
    socket
    |> assign_loaded_draft(stored.draft, actor)
    |> assign_draft_values(
      stored.draft
      |> draft_values()
      |> Map.put("image", LaunchDraftImageStorage.public_url(stored.image))
    )
    |> assign(draft_errors: %{}, image_notice: nil)
  end

  defp load_create(socket, actor) do
    case current_or_new_draft(socket, actor) do
      {:ok, draft} ->
        socket
        |> assign_loaded_draft(draft, actor)
        |> assign(status: :ready)
        |> assign_connections()
        |> check_treasury()

      {:error, _error} ->
        assign(socket, status: :error)
    end
  end

  # Base's own answer, read once the page connects: while the factory has new
  # launches paused, the launch button stays greyed with the reason beside it.
  defp read_launches_paused(socket) do
    if connected?(socket),
      do: start_async(socket, :launches_paused, &LaunchActions.launches_paused/0),
      else: socket
  end

  defp assign_defaults(socket, actor) do
    assign(socket,
      launch_drafts: [],
      draft_values: @stored_params |> Map.new(&{&1, ""}) |> Map.put("treasury_path", "safe"),
      draft_errors: %{},
      draft_notice: nil,
      image_notice: nil,
      image_color: nil,
      creator_connections: %{},
      has_connections: false,
      connections_waived: false,
      no_connections_typed: "",
      reviewing?: false,
      launched?: false,
      listings: 0,
      ticker_taken?: false,
      treasury_check: nil,
      launches_paused?: false,
      current_human_id: actor && actor.human_account_id,
      status: :loading
    )
  end

  defp assign_loaded_draft(socket, draft, actor) do
    socket
    |> assign_draft_values(draft_values(draft))
    |> assign(launch_drafts: [draft], current_human_id: actor.human_account_id, status: :ready)
  end

  # A saved draft's values, with the colour the gallery tints the auction's
  # card with read again only when the draft's image changes.
  defp assign_draft_values(
         %{assigns: %{draft_values: %{"image" => image}}} = socket,
         %{"image" => image} = values
       ),
       do: assign(socket, draft_values: values)

  defp assign_draft_values(socket, %{"image" => image} = values),
    do: assign(socket, draft_values: values, image_color: ImageColor.for_url(image))

  defp assign_ticker_taken(socket),
    do: assign(socket, ticker_taken?: Ticker.taken?(socket.assigns.draft_values["symbol"]))

  # The line beside the treasury box. On the Safe path a whole address is read
  # on Base at the latest block, away from this process, and read again only
  # once the address changes or the last read failed. An answer for an address
  # the box no longer holds is dropped. The local test chain is a Base fork its
  # launch review does not check either, so nothing is read there.
  defp check_treasury(socket) do
    case {safe_address(socket.assigns.draft_values), socket.assigns.treasury_check} do
      {nil, _check} ->
        assign(socket, treasury_check: nil)

      {address, %{address: address, state: state}} when state != :unread ->
        socket

      {address, _check} ->
        socket
        |> assign(treasury_check: %{address: address, state: :checking})
        |> start_async(:treasury_check, fn -> {address, safe_check(address)} end)
    end
  end

  defp safe_address(%{"treasury_path" => "safe", "treasury" => treasury}) do
    if LaunchDraft.treasury_address?(treasury) and not Lab.test_chain?(),
      do: String.downcase(treasury)
  end

  defp safe_address(_values), do: nil

  defp safe_check(address) do
    case TreasurySecurity.safe_check(address) do
      {:ok, answer} -> answer
      {:error, _unread} -> :unread
    end
  end

  defp checked(%{address: address, state: :checking} = check, {:ok, {address, answer}}),
    do: %{check | state: answer}

  defp checked(%{state: :checking} = check, {:exit, _reason}), do: %{check | state: :unread}
  defp checked(check, _stale), do: check

  # Draft writes run under the page's lease read again now
  # (`AutolaunchWeb.Live.Session.transact/2`), so a page whose sign-in could not
  # be read just then writes nothing.
  defp save_draft(socket, actor, write),
    do:
      Session.transact(socket, fn ->
        with {:ok, draft} <- found_or_new_draft(actor), do: write.(draft)
      end)

  defp attach_image(socket, actor, bytes, entry),
    do:
      save_draft(
        socket,
        actor,
        &LaunchDraftImageStorage.store_and_attach(
          &1,
          bytes,
          entry.client_type,
          entry.client_name,
          actor
        )
      )

  defp confirm_treasury(actor, treasury) do
    with {:ok, draft} <- reload_draft(actor),
         do: Autolaunch.confirm_launch_agent_treasury(draft, treasury, actor: actor)
  end

  # The account's draft; a first one is made only under the page's lease read
  # again now, like every other draft write.
  defp current_or_new_draft(socket, actor) do
    case Autolaunch.get_my_account_launch_draft(actor: actor) do
      {:ok, nil} -> Session.transact(socket, fn -> found_or_new_draft(actor) end)
      read -> read
    end
  end

  # Only ever run inside `Session.transact/2`.
  defp found_or_new_draft(actor) do
    case Autolaunch.get_my_account_launch_draft(actor: actor) do
      {:ok, nil} -> Autolaunch.create_launch_draft(%{}, actor: actor)
      read -> read
    end
  end

  defp reload_draft(actor) do
    case Autolaunch.get_my_account_launch_draft(actor: actor) do
      {:ok, nil} -> {:error, :image_unavailable}
      other -> other
    end
  end

  # Whether the creator has any account on show: a checked X account, GitHub
  # or ENS. A Revstake launch without one asks for a typed warning first. With
  # it, the accounts as a listed auction's gallery card shows them, for the
  # card's preview.
  defp assign_connections(%{assigns: %{current_human_id: id}} = socket) do
    x_connections = load_x_connections(account(socket))
    identities = CreatorConnectionsComponent.identities(human_actor(socket))
    creator = %{creator_human_account_id: id}

    assign(socket,
      has_connections:
        Enum.any?(x_connections, &match?(%{verified_at: %DateTime{}}, &1)) or
          Map.take(identities, [:github, :ens]) != %{},
      creator_connections:
        AutolaunchHelpers.connections_for(
          creator,
          AutolaunchHelpers.creator_connections_for([creator])
        )
    )
  end

  defp load_x_connections(nil), do: []

  defp load_x_connections(account) do
    case XOAuth.list_for_account(account) do
      {:ok, connections} -> connections
      {:error, _error} -> []
    end
  end

  defp draft_field_errors({:error, %Ash.Error.Invalid{errors: errors}} = failure) do
    marked =
      for %{field: field} = error <- errors,
          to_string(field) in @stored_params,
          into: %{},
          do: {to_string(field), draft_field_message(error)}

    if marked == %{}, do: unmarked(failure), else: marked
  end

  # A lost connection was logged where the sign-in was read.
  defp draft_field_errors({:error, :sign_in_unread}), do: %{}
  defp draft_field_errors(failure), do: unmarked(failure)

  # Anything but a refused field is not the creator's to fix: it is logged,
  # and the page says to try again.
  defp unmarked(failure) do
    Logger.warning("launch draft could not be saved: #{inspect(failure)}")
    %{}
  end

  defp draft_field_message(%Ash.Error.Changes.Required{}), do: "Fill this in."
  defp draft_field_message(%{message: message}), do: message

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil

  defp account(%{assigns: %{access_context: %{principal: {:human, account}}}}), do: account
  defp account(_socket), do: nil

  # Whether the saved treasury step is done. A Safe treasury is done only once
  # Base shows it is a 2-of-3 Safe; the local test chain is not read, as its
  # launch review does not check the treasury either.
  defp treasury_ready?(draft, check) do
    LaunchDraft.treasury_complete?(draft) and
      (draft.treasury_path != :safe or Lab.test_chain?() or safe_found?(draft.treasury, check))
  end

  defp safe_found?(treasury, %{address: address, state: :two_of_three_safe}),
    do: Address.equal?(treasury, address)

  defp safe_found?(_treasury, _check), do: false

  defp draft_values(draft) do
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

  defp draft_field(assigns) do
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
        phx-debounce="blur"
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
        phx-debounce="blur"
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
end
