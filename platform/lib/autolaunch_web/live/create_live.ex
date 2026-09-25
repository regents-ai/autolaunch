defmodule AutolaunchWeb.CreateLive do
  @moduledoc """
  Agentic Revenue Launch, at /create/revstake: the Revstake launch form on
  Base. Memestock launches have their own page at /create.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.
  """

  use AutolaunchWeb, :live_view

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.{LaunchDraft, LaunchDraftImageStorage, Limits}
  alias Autolaunch.Stocks.MarketData
  alias AutolaunchWeb.CreatorConnectionsComponent
  alias AutolaunchWeb.Live.CreateLive.Templates
  alias AutolaunchWeb.UsdValue

  import AutolaunchWeb.Components.AuctionStats
  import AutolaunchWeb.Components.DraftCarryOver, only: [keep_draft: 2]

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
      |> assign_auction_stats()
      |> assign_defaults(actor)
      |> UsdValue.assign_rate(:regent_usd_rate, :base, fn ->
        {:ok, %{regent_usd_rate: MarketData.regent_price()}}
      end)

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
           socket
           |> load_create(actor)
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

  def handle_event(event, _params, socket)
      when event in ["create_launch_draft", "revise_launch_draft"] do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @autosave_events,
    do: handle_draft_event(event, params["launch_draft"] || %{}, socket)

  # What a visitor typed while signed out, handed back by this tab. Signed in,
  # it goes into the account's draft through the same saves as typing it
  # would; signed out, it refills the unsaved form after a reload.
  def handle_event("restore_draft", %{"values" => values}, socket) when is_map(values),
    do: {:noreply, restore(socket, values)}

  def handle_event("no_connections_typed", %{"typed" => typed}, socket) when is_binary(typed),
    do: {:noreply, assign(socket, no_connections_typed: typed)}

  def handle_event("no_connections_confirmed", %{"typed" => typed}, socket)
      when is_binary(typed) do
    {:noreply,
     assign(socket,
       no_connections_typed: typed,
       connections_waived: String.trim(typed) == Templates.no_connections_acknowledgement()
     )}
  end

  def render(assigns) do
    ~H"""
    <div class="autolaunch-page launchpad-create">
      <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      <header class="launchpad-create__header">
        <div class="launchpad-create__title">
          <Regent.Structure.section_bar>
            <h1 class="rg-section-bar__label">Agentic Revenue Launch</h1>
          </Regent.Structure.section_bar>
          <.link navigate="/create" class="memestock__alt">
            Launch memestock <span aria-hidden="true">→</span>
          </.link>
        </div>
        <p>
          Raise early funds through an auction. It tokenizes a stablecoin generating service or
          agent, and tokenholders stake it to acquire their slice of stablecoin earnings. Bidders
          pay in REGENT, and you can set a minimum REGENT raise. There is no launch fee.
          <.link href="/blog/durable-agent-services">
            Read about building a durable service for one.
          </.link>
        </p>
      </header>
      {render_revshare(assigns)}
    </div>
    """
  end

  # A launch card opened its review, so a saved-draft note no longer describes
  # what this page is doing and comes down.
  def handle_info({:launch_review, :open}, socket),
    do: {:noreply, assign(socket, draft_notice: nil)}

  def handle_info({:creator_connections, :changed}, socket),
    do: {:noreply, assign_connections(socket)}

  defp render_revshare(assigns) do
    assigns =
      assign(assigns,
        launch_image_upload: assigns[:uploads][:launch_image],
        regent_usd_rate: assigns.regent_usd_rate.result
      )

    Templates.create(assigns)
  end

  defp handle_draft_event(event, submitted, socket) do
    values = Map.take(submitted, section_params(event))

    socket =
      case save_section(socket, event, values) do
        {:ok, socket} ->
          assign(socket, draft_errors: %{}, draft_notice: saved_notice(socket))

        {:error, errors} ->
          assign(socket,
            draft_values: Map.merge(socket.assigns.draft_values, values),
            draft_errors: errors,
            draft_notice: unsaved_notice(socket)
          )
      end

    {:noreply, keep(socket)}
  end

  defp section_params("autosave_launch_token_details"), do: Templates.token_detail_params()
  defp section_params("autosave_launch_treasury"), do: Templates.treasury_params()

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
        with {:ok, draft} <- current_or_new_draft(actor),
             {:ok, _saved} <- autosave_draft(event, draft, values, actor),
             {:ok, reloaded} <- reload_draft(actor) do
          {:ok, assign_loaded_draft(socket, reloaded, actor)}
        else
          error -> {:error, draft_field_errors(error)}
        end
    end
  end

  defp saved_notice(%{assigns: %{current_human_id: nil}}), do: nil
  defp saved_notice(_socket), do: %{tone: :success, message: "Saved to your account."}

  defp unsaved_notice(%{assigns: %{current_human_id: nil}}), do: nil

  defp unsaved_notice(_socket),
    do: %{tone: :error, message: "That change could not be saved. Check the marked field."}

  defp restore(%{assigns: %{status: :error}} = socket, _values), do: socket

  defp restore(socket, values) do
    values = Map.filter(values, fn {_param, value} -> is_binary(value) end)

    {socket, unsaved, errors} =
      Enum.reduce(@autosave_events, {socket, %{}, %{}}, &restore_section(&1, &2, values))

    assign(socket,
      draft_values: Map.merge(socket.assigns.draft_values, unsaved),
      draft_errors: errors,
      draft_notice: if(unsaved == %{}, do: saved_notice(socket), else: unsaved_notice(socket))
    )
  end

  # A section that cannot be saved stays on the form as typed, marked.
  defp restore_section(event, {socket, unsaved, errors} = restored, values) do
    case Map.take(values, section_params(event)) do
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
    fresh = Templates.draft_values(%LaunchDraft{})

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
    do:
      assign(socket, sketch: sketch, draft_values: Templates.draft_values(sketch), status: :ready)

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
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, stored} <-
           LaunchDraftImageStorage.store_and_attach(
             draft,
             bytes,
             entry.client_type,
             entry.client_name,
             actor
           ) do
      {:noreply, assign_saved_image(socket, stored, actor)}
    else
      {:error, :image_changed} ->
        {:noreply,
         assign(socket,
           image_notice:
             "The saved image changed while this one was uploading. Your newer image was kept; choose again to replace it."
         )}

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
    |> assign(
      draft_values:
        Templates.draft_values(stored.draft)
        |> Map.put("image", LaunchDraftImageStorage.public_url(stored.image)),
      draft_errors: %{},
      image_notice: nil
    )
  end

  defp load_create(socket, actor) do
    case current_or_new_draft(actor) do
      {:ok, draft} ->
        socket
        |> assign_loaded_draft(draft, actor)
        |> assign(status: :ready)
        |> assign_connections()

      {:error, _error} ->
        assign(socket, status: :error)
    end
  end

  defp assign_defaults(socket, actor) do
    assign(socket,
      launch_drafts: [],
      draft_values: Templates.blank_draft_fields(),
      draft_errors: %{},
      draft_notice: nil,
      image_notice: nil,
      x_connections: [],
      has_connections: false,
      connections_waived: false,
      no_connections_typed: "",
      x_oauth_enabled: XOAuth.enabled?(),
      auction_limit_reached: auction_limit_reached?(actor),
      current_human_id: actor && actor.human_account_id,
      status: :loading
    )
  end

  defp assign_loaded_draft(socket, draft, actor) do
    assign(socket,
      launch_drafts: [draft],
      draft_values: Templates.draft_values(draft),
      auction_limit_reached: auction_limit_reached?(actor),
      current_human_id: actor.human_account_id,
      status: :ready
    )
  end

  defp current_or_new_draft(actor) do
    case Autolaunch.get_my_account_launch_draft(actor: actor) do
      {:ok, nil} -> Autolaunch.create_launch_draft(%{}, actor: actor)
      {:ok, draft} -> {:ok, draft}
      {:error, error} -> {:error, error}
    end
  end

  defp reload_draft(actor) do
    case Autolaunch.get_my_account_launch_draft(actor: actor) do
      {:ok, nil} -> {:error, :image_unavailable}
      other -> other
    end
  end

  # Whether the creator has any account on show: a checked X account, GitHub
  # or ENS. A Revstake launch without one asks for a typed warning first.
  defp assign_connections(socket) do
    x_connections = load_x_connections(account(socket))
    identities = CreatorConnectionsComponent.identities(human_actor(socket))

    assign(socket,
      x_connections: x_connections,
      has_connections:
        Enum.any?(x_connections, &match?(%{verified_at: %DateTime{}}, &1)) or
          Map.take(identities, [:github, :ens]) != %{}
    )
  end

  defp load_x_connections(nil), do: []

  defp load_x_connections(account) do
    case XOAuth.list_for_account(account) do
      {:ok, connections} -> connections
      {:error, _error} -> []
    end
  end

  defp auction_limit_reached?(%Human{human_account_id: id}) do
    Autolaunch.auctions_prepared_by(id) >= Limits.auctions_per_account()
  end

  defp auction_limit_reached?(_actor), do: false

  defp draft_field_errors({:error, %Ash.Error.Invalid{errors: errors}}) do
    params = Templates.draft_field_params()

    for %{field: field} = error <- errors,
        to_string(field) in params,
        into: %{},
        do: {to_string(field), draft_field_message(error)}
  end

  defp draft_field_errors(_error), do: %{}

  defp draft_field_message(%Ash.Error.Changes.Required{}), do: "is required"
  defp draft_field_message(%{message: message}), do: message

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil

  defp account(%{assigns: %{access_context: %{principal: {:human, account}}}}), do: account
  defp account(_socket), do: nil
end
