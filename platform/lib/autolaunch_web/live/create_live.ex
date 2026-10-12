defmodule AutolaunchWeb.CreateLive do
  @moduledoc """
  Create a Revstake token, at /create/revstake: the Revstake launch form on
  Base. Memestock launches have their own page at /create.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.
  """

  use AutolaunchWeb, :live_view

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.{Lab, LaunchDraft, LaunchDraftImageStorage, Listings, Ticker, TreasurySecurity}
  alias AutolaunchWeb.CreatorConnectionsComponent
  alias AutolaunchWeb.Live.CreateLive.Templates

  import AutolaunchWeb.Components.DraftCarryOver, only: [keep_draft: 2]
  import AutolaunchWeb.Components.LaunchKindChoice

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
      |> assign(AutolaunchWeb.PublicDocuments.page("/create/revstake"))
      |> assign_defaults(actor)

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

  def handle_event(event, params, socket) when event in @autosave_events,
    do: handle_draft_event(event, params["launch_draft"] || %{}, socket)

  # What a visitor typed while signed out, handed back by this tab. Signed in,
  # it goes into the account's draft through the same saves as typing it
  # would; signed out, it refills the unsaved form after a reload. A draft
  # that could not be read takes nothing, and the tab keeps the values.
  def handle_event("restore_draft", %{"values" => values}, socket) when is_map(values) do
    if socket.assigns.status == :error,
      do: {:reply, %{taken: false}, socket},
      else: {:reply, %{taken: true}, restore(socket, values)}
  end

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
    <main class="create-page">
      <.launch_kind_choice current={:revstake} />
      <header class="create-page__header">
        <h1>Create a Revstake token</h1>
      </header>
      {render_revshare(assigns)}
    </main>
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
    socket = assign(socket, reviewing?: false, launched?: news == :launched)

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

  def handle_async(:treasury_check, result, socket),
    do: {:noreply, assign(socket, treasury_check: checked(socket.assigns.treasury_check, result))}

  defp render_revshare(assigns) do
    assigns = assign(assigns, launch_image_upload: assigns[:uploads][:launch_image])

    Templates.create(assigns)
  end

  defp handle_draft_event(event, submitted, socket),
    do: {:noreply, autosaved(socket, event, Map.take(submitted, section_params(event)))}

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
            draft_notice: unsaved_notice(socket)
          )
      end

    socket |> assign_ticker_taken() |> check_treasury() |> keep()
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

  defp restore(socket, values) do
    values = Map.filter(values, fn {_param, value} -> is_binary(value) end)

    {socket, unsaved, errors} =
      Enum.reduce(@autosave_events, {socket, %{}, %{}}, &restore_section(&1, &2, values))

    socket
    |> assign(
      draft_values: Map.merge(socket.assigns.draft_values, unsaved),
      draft_errors: errors,
      draft_notice: if(unsaved == %{}, do: saved_notice(socket), else: unsaved_notice(socket))
    )
    |> assign_ticker_taken()
    |> check_treasury()
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
        |> check_treasury()

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
      has_connections: false,
      connections_waived: false,
      no_connections_typed: "",
      reviewing?: false,
      launched?: false,
      listings: 0,
      ticker_taken?: false,
      treasury_check: nil,
      current_human_id: actor && actor.human_account_id,
      status: :loading
    )
  end

  defp assign_loaded_draft(socket, draft, actor) do
    assign(socket,
      launch_drafts: [draft],
      draft_values: Templates.draft_values(draft),
      current_human_id: actor.human_account_id,
      status: :ready
    )
  end

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
