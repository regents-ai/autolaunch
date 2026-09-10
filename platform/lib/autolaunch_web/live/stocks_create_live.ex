defmodule AutolaunchWeb.StocksCreateLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks
  alias Autolaunch.Stocks.LaunchDraftImageStorage
  alias AutolaunchWeb.Live.StocksCreateLive.Templates

  @autosave_events ~w(autosave_stocks_token_details autosave_stocks_terms autosave_stocks_revenue)

  # A signed-out visitor stays on this route, exactly as on /create: the page
  # explains the sign-in requirement and a completed sign-in reloads it.
  def mount(_params, _session, socket) do
    case human_actor(socket) do
      nil ->
        {:ok, assign(socket, status: :sign_in_required)}

      actor ->
        socket =
          socket
          |> allow_upload(:stocks_image,
            accept: ~w(.png .jpg .jpeg .webp),
            max_entries: 1,
            max_file_size: 2_097_152,
            auto_upload: true,
            progress: &handle_stocks_image_progress/3
          )
          |> assign(
            draft: nil,
            draft_values: Templates.blank_draft_fields(),
            draft_errors: %{},
            draft_notice: nil,
            image_notice: nil,
            image_request: nil,
            current_human_id: actor.human_account_id,
            stocks_lab: stocks_lab(),
            active_stocks_launch: active_stocks_launch?(actor),
            status: :loading
          )

        {:ok, if(connected?(socket), do: load_draft(socket, actor), else: socket)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Client events are not proof of ownership; the anonymous entry has no draft.
  def handle_event(_event, _params, %{assigns: %{status: :sign_in_required}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @autosave_events do
    socket =
      if event == "autosave_stocks_token_details" and
           socket.assigns.uploads.stocks_image.entries != [],
         do: cancel_image_fetch(socket),
         else: socket

    values = Map.take(params["stock_draft"] || %{}, Templates.section_params(event))

    with %Human{} = actor <- human_actor(socket),
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, saved} <- autosave(event, draft, values, actor) do
      {:noreply,
       socket
       |> assign_draft(saved)
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

  def handle_event("stocks_fetch_image_url", params, socket) do
    url = params |> Map.get("url", "") |> to_string() |> String.trim()

    with %Human{} = actor <- human_actor(socket),
         {:ok, draft} <- current_or_new_draft(actor) do
      request_id = make_ref()
      socket = cancel_image_fetch(socket)

      socket =
        Enum.reduce(socket.assigns.uploads.stocks_image.entries, socket, fn entry, acc ->
          cancel_upload(acc, :stocks_image, entry.ref)
        end)

      {:noreply,
       socket
       |> assign(
         image_request: request_id,
         image_notice: %{tone: :info, message: "Fetching image…"}
       )
       |> start_async({:fetch_image_url, request_id}, fn ->
         with {:ok, image} <- LaunchDraftImageStorage.fetch(url), do: {:ok, {draft, image}}
       end)}
    else
      _error ->
        {:noreply, assign(socket, image_notice: image_notice(:fetch_failed))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def handle_async({:fetch_image_url, request_id}, result, socket) do
    if socket.assigns.image_request == request_id do
      finish_image_fetch(result, assign(socket, image_request: nil))
    else
      {:noreply, socket}
    end
  end

  def render(%{status: :sign_in_required} = assigns) do
    ~H"""
    <main class="launchpad-create">
      <section
        id="autolaunch-stocks-create-sign-in"
        class="autolaunch-empty launchpad-create__sign-in"
      >
        <p class="autolaunch-kicker">Autolaunch · Create · Stocks</p>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Sign in to launch a stock-paired auction</h1>
        </Regent.Structure.section_bar>
        <p>
          A launch starts as a private draft saved to your account, so Create needs you signed
          in. Once you are, you come straight back here.
        </p>
        <Regent.Primitives.button
          type="button"
          class="account-control__sign-in"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
      </section>
    </main>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :stocks_image_upload, assigns.uploads[:stocks_image])
    Templates.create(assigns)
  end

  defp autosave("autosave_stocks_token_details", draft, values, actor),
    do: Autolaunch.autosave_stocks_token_details(draft, values, actor: actor)

  defp autosave("autosave_stocks_terms", draft, values, actor),
    do: Autolaunch.autosave_stocks_terms(draft, values, actor: actor)

  defp autosave("autosave_stocks_revenue", draft, values, actor),
    do: Autolaunch.autosave_stocks_revenue(draft, values, actor: actor)

  defp handle_stocks_image_progress(:stocks_image, entry, socket) do
    socket = cancel_image_fetch(socket)

    if entry.done?,
      do: finish_stocks_image(entry, socket),
      else: {:noreply, socket}
  end

  # Phoenix supplies the completed-upload temp path; it is never accepted from
  # request parameters or other user-controlled path input.
  # sobelow_skip ["Traversal.FileModule"]
  defp finish_stocks_image(entry, socket) do
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
      {:noreply, assign_saved_image(socket, stored)}
    else
      {:error, :image_changed} ->
        {:noreply, assign(socket, image_notice: image_notice(:image_changed))}

      _error ->
        {:noreply,
         assign(socket,
           image_notice: %{
             tone: :error,
             message: "That file is not a complete PNG, JPEG, or WebP image under 2 MB."
           }
         )}
    end
  end

  defp assign_saved_image(socket, stored) do
    socket
    |> assign_draft(stored.draft)
    |> assign(
      draft_values:
        Templates.draft_values(stored.draft)
        |> Map.put("image", LaunchDraftImageStorage.public_url(stored.image)),
      draft_errors: %{},
      image_notice: %{
        tone: :success,
        message: "Image saved. You can replace it with a file or image link."
      }
    )
  end

  defp cancel_image_fetch(%{assigns: %{image_request: nil}} = socket), do: socket

  defp cancel_image_fetch(socket) do
    socket
    |> cancel_async({:fetch_image_url, socket.assigns.image_request})
    |> assign(image_request: nil, image_notice: nil)
  end

  defp finish_image_fetch({:ok, {:ok, {draft, image}}}, socket) do
    actor = human_actor(socket)

    case LaunchDraftImageStorage.store_and_attach(
           draft,
           image.bytes,
           image.content_type,
           image.original_filename,
           actor
         ) do
      {:ok, stored} -> {:noreply, assign_saved_image(socket, stored)}
      {:error, reason} -> {:noreply, assign(socket, image_notice: image_notice(reason))}
    end
  end

  defp finish_image_fetch({:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, image_notice: image_notice(reason))}

  defp finish_image_fetch(_failure, socket),
    do: {:noreply, assign(socket, image_notice: image_notice(:fetch_failed))}

  defp load_draft(socket, actor) do
    case current_or_new_draft(actor) do
      {:ok, draft} ->
        socket
        |> assign_draft(draft)
        |> assign(status: :ready, active_stocks_launch: active_stocks_launch?(actor))

      {:error, _error} ->
        assign(socket, status: :error)
    end
  end

  # The site rule mirrored on the page: one stock auction in progress per account.
  defp active_stocks_launch?(%Human{human_account_id: id}),
    do: Autolaunch.active_stocks_auctions_by(id) > 0

  defp assign_draft(socket, draft) do
    assign(socket,
      draft: draft,
      draft_values: Templates.draft_values(draft),
      status: :ready
    )
  end

  defp current_or_new_draft(actor) do
    case Autolaunch.get_my_stocks_launch_draft(actor: actor) do
      {:ok, nil} -> Autolaunch.create_stocks_launch_draft(%{}, actor: actor)
      other -> other
    end
  end

  defp stocks_lab do
    case Stocks.Lab.current() do
      {:ok, config} -> config
      {:error, _reason} -> nil
    end
  end

  defp draft_field_errors({:error, %Ash.Error.Invalid{errors: errors}}) do
    params = Templates.draft_field_params()

    for %{field: field} = error <- errors,
        to_string(field) in params,
        into: %{},
        do: {to_string(field), error_message(error)}
  end

  defp draft_field_errors(_error), do: %{}

  defp error_message(%Ash.Error.Changes.Required{}), do: "is required"
  defp error_message(%{message: message}), do: message

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

  defp image_notice(:image_changed),
    do: %{
      tone: :error,
      message:
        "The saved image changed while this image was loading. Your newer image was kept; try again to replace it."
    }

  defp image_notice(_reason),
    do: %{tone: :error, message: "We could not load that image. Try another link."}

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil
end
