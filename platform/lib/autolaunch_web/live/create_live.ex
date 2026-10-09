defmodule AutolaunchWeb.CreateLive do
  @moduledoc """
  Create a Revstake token, at /create/revstake: the Revstake launch form on
  Base. Memestake launches have their own page at /create.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.

  An agent reads the form with `autolaunch_launch_form` and fills it with
  `autolaunch_fill_revstake`, through the same saves as typing
  (`assets/js/hooks/agent_tools.ts`). The picture and both typed warnings stay
  with the person.
  """

  use AutolaunchWeb, :live_view

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.{Lab, LaunchDraft, LaunchDraftImageStorage, Ticker, TreasurySecurity}
  alias AutolaunchWeb.{CreatorConnectionsComponent, DraftMarks}
  alias AutolaunchWeb.Live.CreateLive.Templates

  import AutolaunchWeb.Components.DraftCarryOver, only: [keep_draft: 2]
  import AutolaunchWeb.Components.LaunchKindChoice

  @autosave_events ["autosave_launch_token_details", "autosave_launch_treasury"]
  # The single-key warning is the person's to type.
  @agent_treasury_params ["treasury_path", "treasury"]
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

  def handle_event("agent_call", %{"tool" => "autolaunch_launch_form"}, socket),
    do: {:reply, form_state(socket), socket}

  def handle_event(
        "agent_call",
        %{"tool" => "autolaunch_fill_revstake", "input" => input},
        socket
      )
      when is_map(input) do
    case agent_filled(socket, input) do
      {:ok, %{assigns: %{draft_errors: errors}} = socket} when errors == %{} ->
        {:reply, %{outcome: "saved", form: form_state(socket)}, socket}

      {:ok, socket} ->
        {:reply,
         %{
           outcome: "not_saved",
           message: "The fields named in problems were not saved; the rest were.",
           form: form_state(socket)
         }, socket}

      {:error, message, socket} ->
        {:reply, %{outcome: "not_saved", message: message, form: form_state(socket)}, socket}
    end
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

  # An agent's fill: the token details, then the treasury, each saved as
  # typing it on the page would save it. A section that is not saved stays
  # marked while the next one saves.
  defp agent_filled(%{assigns: %{status: status}} = socket, _input) when status != :ready,
    do: {:error, "The draft could not be loaded. Ask the person to refresh the page.", socket}

  defp agent_filled(%{assigns: %{reviewing?: true}} = socket, _input),
    do:
      {:error,
       "The details are locked while the launch review is open on the page. Ask the person to cancel the review to change them.",
       socket}

  defp agent_filled(socket, input) do
    {socket, errors} =
      [
        {"autosave_launch_token_details", Templates.token_detail_params()},
        {"autosave_launch_treasury", @agent_treasury_params}
      ]
      |> Enum.reduce({socket, %{}}, fn {event, params}, {socket, errors} ->
        case Map.take(input, params) do
          values when values == %{} ->
            {socket, errors}

          values ->
            socket = autosaved(socket, event, values)
            {socket, Map.merge(errors, socket.assigns.draft_errors)}
        end
      end)

    notice = if errors == %{}, do: saved_notice(socket), else: unsaved_notice(socket)
    {:ok, assign(socket, draft_errors: errors, draft_notice: notice)}
  end

  # The form as an agent reads it. The fields are what a person typed.
  defp form_state(%{assigns: assigns}) do
    %{
      launch: "revstake",
      chain: "base",
      signed_in: is_integer(assigns.current_human_id),
      fields:
        Map.take(
          assigns.draft_values,
          Templates.token_detail_params() ++ @agent_treasury_params
        ),
      picture: assigns.draft_values["image"] != "",
      problems: assigns.draft_errors,
      next: next_step(assigns)
    }
  end

  defp next_step(%{status: status}) when status != :ready,
    do: "The draft could not be loaded. Ask the person to refresh the page."

  defp next_step(%{reviewing?: true}),
    do:
      "The launch review is open on the page. Call autolaunch_launch to send it to the person's wallet."

  defp next_step(%{current_human_id: nil}),
    do:
      "The person is not signed in. What you fill stays in this browser tab and is saved to their account once they sign in on the page. Launching needs them signed in."

  defp next_step(%{launch_drafts: [draft | _rest]} = assigns) do
    case still_needed(draft, assigns.treasury_check) do
      [] ->
        if assigns.has_connections or assigns.connections_waived,
          do: "Ready. Call autolaunch_launch to review the launch and open the person's wallet.",
          else:
            "Ready, once the person connects X, GitHub or ENS on the page, or types the warning shown there that the launch may not appear in the gallery. Then call autolaunch_launch."

      needed ->
        "Still needed: #{Enum.join(needed, "; ")}."
    end
  end

  defp still_needed(draft, check) do
    details =
      case LaunchDraft.missing_token_details(draft) -- [:image] do
        [] -> []
        missing -> [DraftMarks.still_needed(missing)]
      end

    picture =
      if LaunchDraft.image_complete?(draft),
        do: [],
        else: ["the picture, which the person chooses on the page"]

    details ++ picture ++ treasury_needed(draft, check)
  end

  defp treasury_needed(draft, check) do
    cond do
      Templates.treasury_ready?(draft, check) ->
        []

      LaunchDraft.treasury_complete?(draft) ->
        ["a treasury address that is a 2-of-3 Safe on Base"]

      LaunchDraft.treasury_address?(draft.treasury) ->
        ["the single-key warning, which the person types on the page"]

      true ->
        ["the treasury address"]
    end
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
