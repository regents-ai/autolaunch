defmodule AutolaunchWeb.CreateLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Accounts.XOAuth
  alias Autolaunch.Actors.Human
  alias Autolaunch.{LaunchChain, LaunchDraftImageStorage, Limits}
  alias AutolaunchWeb.Live.CreateLive.Templates

  import AutolaunchWeb.Components.AuctionStats

  @autosave_events ["autosave_launch_token_details", "autosave_launch_treasury"]

  # A signed-out visitor stays on this route: the page explains the sign-in
  # requirement, and a completed sign-in reloads the same document, so the
  # visitor returns to Create without any redirect parameter to validate.
  def mount(params, session, socket) do
    chain = LaunchChain.from_param(params["chain"])
    kind = launch_kind(chain, params)

    socket =
      socket
      |> assign(launch_kind: kind, launch_chain: chain)
      |> assign_auction_stats()

    mount_kind(kind, params, session, socket)
  end

  # Robinhood launches Memestake tokens only; Base launches either type, and a
  # link that names a stock (`token=`) means a Memestake token.
  defp launch_kind(:robinhood, _params), do: :stocks
  defp launch_kind(:base, %{"kind" => "stocks"}), do: :stocks
  defp launch_kind(:base, %{"token" => token}) when is_binary(token) and token != "", do: :stocks
  defp launch_kind(:base, _params), do: :revshare

  defp mount_kind(:stocks, params, session, socket),
    do: AutolaunchWeb.StocksCreateLive.mount(params, session, socket)

  defp mount_kind(:revshare, _params, _session, socket) do
    case human_actor(socket) do
      nil ->
        {:ok, assign(socket, status: :sign_in_required)}

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

  def handle_event(event, params, %{assigns: %{launch_kind: :stocks}} = socket),
    do: AutolaunchWeb.StocksCreateLive.handle_event(event, params, socket)

  # The anonymous entry has no draft or upload state. Client events are not
  # proof of ownership and must not enter handlers requiring that state.
  def handle_event(_event, _params, %{assigns: %{status: :sign_in_required}} = socket),
    do: {:noreply, socket}

  def handle_event(event, _params, socket)
      when event in ["create_launch_draft", "revise_launch_draft"] do
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in @autosave_events do
    socket =
      if event == "autosave_launch_token_details" and
           socket.assigns.uploads.launch_image.entries != [],
         do: cancel_image_fetch(socket),
         else: socket

    handle_draft_event(event, params["launch_draft"] || %{}, socket)
  end

  def handle_event("fetch_image_url", params, socket) do
    url = params |> Map.get("url", "") |> to_string() |> String.trim()
    actor = human_actor(socket)

    with %Human{} = actor <- actor,
         {:ok, draft} <- current_or_new_draft(actor) do
      request_id = make_ref()
      socket = cancel_image_fetch(socket)

      socket =
        Enum.reduce(socket.assigns.uploads.launch_image.entries, socket, fn entry, acc ->
          cancel_upload(acc, :launch_image, entry.ref)
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

  def handle_event("refresh_x_connections", _params, socket) do
    {:noreply, assign(socket, x_connections: load_x_connections(account(socket)))}
  end

  def handle_async(name, result, %{assigns: %{launch_kind: :stocks}} = socket),
    do: AutolaunchWeb.StocksCreateLive.handle_async(name, result, socket)

  def handle_async({:fetch_image_url, request_id}, result, socket) do
    if socket.assigns.image_request == request_id do
      finish_image_fetch(result, assign(socket, image_request: nil))
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="autolaunch-page launchpad-create">
      <.auction_stats revstake={@revstake_stats} memestake={@memestake_stats} />
      <header class="launchpad-create__header">
        <p class="autolaunch-kicker">Autolaunch · Create</p>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">Launch a token</h1>
        </Regent.Structure.section_bar>
        <div class="launchpad-create__choices">
          <nav class="launchpad-create__choice" aria-label="Choose blockchain">
            <p class="autolaunch-kicker">Choose blockchain</p>
            <div class="launchpad-create__kinds">
              <.link
                :for={chain <- LaunchChain.chains()}
                href={create_path(chain, @launch_kind)}
                class={kind_class(@launch_chain == chain)}
                aria-current={if @launch_chain == chain, do: "page"}
              >{LaunchChain.label(chain)}</.link>
            </div>
          </nav>
          <nav class="launchpad-create__choice" aria-label="Choose token type">
            <p class="autolaunch-kicker">Choose token type</p>
            <div class="launchpad-create__kinds">
              <.link
                :if={@launch_chain == :base}
                href={create_path(:base, :revshare)}
                class={kind_class(@launch_kind == :revshare)}
                aria-current={if @launch_kind == :revshare, do: "page"}
              >Revstake token</.link>
              <Regent.Primitives.button
                :if={@launch_chain == :robinhood}
                id="launch-kind-revstake-unavailable"
                variant="secondary"
                disabled
                aria-describedby="launch-kind-robinhood-note"
              >Revstake token</Regent.Primitives.button>
              <.link
                href={create_path(@launch_chain, :stocks)}
                class={kind_class(@launch_kind == :stocks)}
                aria-current={if @launch_kind == :stocks, do: "page"}
              >Memestake token</.link>
            </div>
            <p
              :if={@launch_chain == :robinhood}
              id="launch-kind-robinhood-note"
              class="launchpad-create__choice-note"
            >
              Robinhood launches Memestake tokens only. Revstake tokens launch on Base.
            </p>
          </nav>
          <p class="launchpad-create__choice-summary" role="status">
            <strong>{choice_title(@launch_chain, @launch_kind)}.</strong>
            {choice_summary(@launch_chain, @launch_kind)}
            <.link :if={@launch_kind == :revshare} href="/blog/durable-agent-services">
              Read about building a durable service for one.
            </.link>
          </p>
        </div>
      </header>
      <%= if @launch_kind == :stocks do %>
        {AutolaunchWeb.StocksCreateLive.render(assigns)}
      <% else %>
        {render_revshare(assigns)}
      <% end %>
    </div>
    """
  end

  defp kind_class(selected?),
    do: ["rg-button", if(selected?, do: "rg-button--primary", else: "rg-button--secondary")]

  defp choice_title(:base, :revshare), do: "Revstake token on Base"
  defp choice_title(chain, :stocks), do: "Memestake token on #{LaunchChain.label(chain)}"

  # What each of the three launches does and which tokens it needs. There is
  # no launch fee on any of them.
  defp choice_summary(:base, :revshare),
    do:
      "Raise early funds through a CCA auction. It tokenizes a stablecoin generating service or agent, and tokenholders stake it to acquire their slice of stablecoin earnings. Bidders pay in REGENT and you choose the required raise in REGENT. There is no launch fee."

  defp choice_summary(:base, :stocks),
    do:
      "A 24 hour auction for a new token paired with an onchain stock. Stakers earn the onchain stock from fees. Bidders pay in the stock token you choose, and you set the required raise in that stock. There is no launch fee."

  defp choice_summary(:robinhood, :stocks) do
    summary =
      "A 24 hour auction for a new token paired with an onchain stock. Stakers earn the onchain stock from fees. Bidders pay in USDG, which is converted into the stock you choose, and you set the required raise in that stock. There is no launch fee."

    if Autolaunch.Robinhood.Lab.configured?(),
      do: summary,
      else: summary <> " Not live yet: your draft is saved until it opens."
  end

  # Base and Revstake are the page's defaults, so only the other choices name
  # themselves in the address. Robinhood has one type, so its chain names it.
  defp create_path(:base, :revshare), do: "/create"
  defp create_path(:base, :stocks), do: "/create?kind=stocks"
  defp create_path(:robinhood, _kind), do: "/create?chain=robinhood"

  # A launch card opened its review, so a saved-draft note no longer describes
  # what this page is doing and comes down.
  def handle_info({:launch_review, :open}, socket),
    do: {:noreply, assign(socket, draft_notice: nil)}

  defp render_revshare(%{status: :sign_in_required} = assigns) do
    ~H"""
    <main class="launchpad-create">
      <section id="autolaunch-create-sign-in" class="autolaunch-empty launchpad-create__sign-in">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label">Sign in to launch an auction</h2>
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

  defp render_revshare(assigns) do
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
         draft_notice: %{tone: :success, message: "Saved to your account."}
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
    socket = cancel_image_fetch(socket)

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

  defp assign_saved_image(socket, stored, actor) do
    socket
    |> assign_loaded_draft(stored.draft, actor)
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
      {:ok, stored} -> {:noreply, assign_saved_image(socket, stored, actor)}
      {:error, reason} -> {:noreply, assign(socket, image_notice: image_notice(reason))}
    end
  end

  defp finish_image_fetch({:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, image_notice: image_notice(reason))}

  defp finish_image_fetch(_failure, socket),
    do: {:noreply, assign(socket, image_notice: image_notice(:fetch_failed))}

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
      image_notice: nil,
      image_request: nil,
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

  defp account(%{assigns: %{access_context: %{principal: {:human, account}}}}), do: account
  defp account(_socket), do: nil
end
