defmodule AutolaunchWeb.CreateLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.LaunchDraftImageStorage
  alias Autolaunch.Limits
  alias AutolaunchWeb.Live.CreateLive.Templates

  @autosave_events ["autosave_launch_token_details", "autosave_launch_treasury"]

  def mount(_params, _session, socket) do
    case human_actor(socket) do
      nil ->
        {:ok, redirect(socket, to: "/")}

      actor ->
        socket =
          socket
          |> allow_upload(:launch_image,
            accept: ~w(.png .jpg .jpeg .webp),
            max_entries: 1,
            max_file_size: 2_097_152,
            auto_upload: true,
            progress: &handle_launch_image_progress/3
          )
          |> assign_defaults(actor)

        {:ok, if(connected?(socket), do: load_create(socket, actor), else: socket)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event(event, _params, socket)
      when event in ["create_launch_draft", "revise_launch_draft"] do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @autosave_events do
    handle_draft_event(event, params["launch_draft"] || %{}, socket)
  end

  def handle_event("fetch_image_url", params, socket) do
    url = params |> Map.get("url", "") |> to_string() |> String.trim()
    actor = human_actor(socket)

    with %Human{} = actor <- actor,
         {:ok, draft} <- current_or_new_draft(actor) do
      {:noreply,
       socket
       |> assign(draft_notice: %{tone: :success, message: "Looking up that image."})
       |> start_async(:fetch_image_url, fn ->
         LaunchDraftImageStorage.store_fetched(draft, url, actor)
       end)}
    else
      _error ->
        {:noreply, assign(socket, draft_notice: image_notice(:fetch_failed))}
    end
  end

  def handle_event("refresh_x_connections", _params, socket) do
    {:noreply, assign(socket, x_connections: load_x_connections(account(socket)))}
  end

  def handle_async(:fetch_image_url, {:ok, {:ok, stored}}, socket) do
    {:noreply, assign_saved_image(socket, stored, human_actor(socket))}
  end

  def handle_async(:fetch_image_url, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, draft_notice: image_notice(reason))}
  end

  def handle_async(:fetch_image_url, {:exit, _reason}, socket) do
    {:noreply, assign(socket, draft_notice: image_notice(:fetch_failed))}
  end

  def render(assigns) do
    assigns = assign(assigns, :launch_image_upload, assigns.uploads[:launch_image])
    Templates.create(assigns)
  end

  defp handle_draft_event(event, submitted, socket) do
    params =
      if event == "autosave_launch_token_details",
        do: Templates.token_detail_params(),
        else: Templates.treasury_params()

    values = Map.take(submitted, params)

    with %Human{} = actor <- human_actor(socket),
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, _saved} <- autosave_draft(event, draft, values, actor),
         {:ok, reloaded} <- reload_draft(actor) do
      {:noreply,
       socket
       |> assign_loaded_draft(reloaded, actor)
       |> assign(
         draft_errors: %{},
         draft_notice: %{
           tone: :success,
           message: "Saved to your account. Nothing has been published and no money has moved."
         }
       )}
    else
      error ->
        {:noreply,
         assign(socket,
           draft_values: Map.merge(socket.assigns.draft_values, values),
           draft_errors: draft_field_errors(error),
           draft_notice: %{
             tone: :error,
             message: "That change could not be saved. Check the marked field."
           }
         )}
    end
  end

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
      {:error, :image_limit_reached} ->
        {:noreply, assign(socket, draft_notice: image_notice(:image_limit_reached))}

      _error ->
        {:noreply,
         assign(socket,
           draft_notice: %{
             tone: :error,
             message: "That file is not a complete PNG, JPEG, or WebP image under 2 MB."
           }
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
      draft_notice: %{tone: :success, message: "Image saved to your account."}
    )
  end

  defp load_create(socket, actor) do
    case current_or_new_draft(actor) do
      {:ok, draft} ->
        socket
        |> assign_loaded_draft(draft, actor)
        |> assign(
          x_connections: load_x_connections(account(socket)),
          status: :ready
        )

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
      x_connections: [],
      x_oauth_enabled: XOAuth.enabled?(),
      auction_limit_reached: auction_limit_reached?(actor),
      current_human_id: actor.human_account_id,
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

  defp image_notice(:unsupported_scheme),
    do: %{tone: :error, message: "Use a web link that starts with http or https."}

  defp image_notice(:private_address),
    do: %{
      tone: :error,
      message:
        "That link points somewhere we can't reach from the internet. Try a public image link."
    }

  defp image_notice(:too_many_redirects),
    do: %{
      tone: :error,
      message: "That link sent us in too many circles. Try a more direct image link."
    }

  defp image_notice(:image_too_large),
    do: %{tone: :error, message: "That image is larger than 2 MB. Choose a smaller one."}

  defp image_notice(:invalid_image),
    do: %{tone: :error, message: "That link did not give us a PNG, JPEG, or WebP image."}

  defp image_notice(:nxdomain),
    do: %{tone: :error, message: "We could not find that site. Check the link and try again."}

  defp image_notice(:image_limit_reached),
    do: %{tone: :error, message: "This launch already has its image."}

  defp image_notice(_reason),
    do: %{tone: :error, message: "We could not load that image. Try another link."}

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil

  defp account(%{assigns: %{access_context: %{principal: {:human, account}}}}), do: account
  defp account(_socket), do: nil
end
