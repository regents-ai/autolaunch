defmodule AutolaunchWeb.StocksCreateLive do
  @moduledoc """
  Launch memestock, at /create: one form for the account's one Memestake
  draft. The Base and Robinhood switch moves the draft between chains; every
  field autosaves.
  """

  use AutolaunchWeb, :live_view

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks
  alias Autolaunch.Stocks.LaunchDraftImageStorage
  alias AutolaunchWeb.Live.StocksCreateLive.Templates

  @autosave_events ~w(autosave_stocks_token_details autosave_stocks_terms)
  @chains %{"base" => :base, "robinhood" => :robinhood}

  # A signed-out visitor stays on this route: the page explains the sign-in
  # requirement and a completed sign-in reloads it.
  def mount(params, _session, socket) do
    socket = assign(socket, launch_chain: :base)

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
            current_human_id: actor.human_account_id,
            stocks_lab: stocks_lab(),
            market: %{prices: %{}, venues: []},
            live_memestake?: false,
            status: :loading
          )

        {:ok,
         if connected?(socket) do
           socket
           |> load_draft(actor)
           |> choose_linked_stock(params["token"], actor)
           |> assign_market()
         else
           socket
         end}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # The chain's stock prices and the chosen stock's venues are read in the
  # background: the page renders without them and fills them in when they land.
  defp assign_market(socket) do
    chain = socket.assigns.launch_chain
    stock = chosen_stock(chain, socket.assigns.draft)
    start_async(socket, :market, fn -> Stocks.MarketData.overview(chain, stock) end)
  end

  defp chosen_stock(chain, %{stock_address: address}) when is_binary(address) do
    case Stocks.Assets.named(chain, address) do
      {:ok, stock} -> stock
      :error -> nil
    end
  end

  defp chosen_stock(_chain, _draft), do: nil

  defp refresh_market(socket, %{stock_address: same}, %{stock_address: same}), do: socket
  defp refresh_market(socket, _before, _changed), do: assign_market(socket)

  # Client events are not proof of ownership; the anonymous entry has no draft.
  def handle_event(_event, _params, %{assigns: %{status: :sign_in_required}} = socket),
    do: {:noreply, socket}

  def handle_event(event, params, socket) when event in @autosave_events do
    values = Map.take(params["stock_draft"] || %{}, Templates.section_params(event))

    with %Human{} = actor <- human_actor(socket),
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, saved} <- autosave(event, draft, values, actor) do
      {:noreply,
       socket
       |> assign_draft(saved)
       |> refresh_market(draft, saved)
       |> assign(draft_errors: %{}, draft_notice: %{tone: :success, message: "Saved"})}
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

  def handle_event("choose_chain", %{"chain" => chain}, socket) when is_map_key(@chains, chain) do
    chain = Map.fetch!(@chains, chain)

    with true <- chain != socket.assigns.launch_chain,
         %Human{} = actor <- human_actor(socket),
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, saved} <- Autolaunch.choose_stocks_launch_chain(draft, chain, actor: actor) do
      {:noreply,
       socket
       |> assign_draft(saved)
       |> assign(draft_errors: %{}, draft_notice: nil, market: %{prices: %{}, venues: []})
       |> assign_market()}
    else
      false ->
        {:noreply, socket}

      _error ->
        {:noreply,
         assign(socket,
           draft_notice: %{tone: :error, message: "The chain could not be changed. Try again."}
         )}
    end
  end

  # The X connect button reloads the socials panel once the account is linked.
  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "creator-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A launch card opened its review, so the saved note no longer describes
  # what this page is doing and comes down.
  def handle_info({:launch_review, :open}, socket),
    do: {:noreply, assign(socket, draft_notice: nil)}

  def handle_async(:market, {:ok, market}, socket), do: {:noreply, assign(socket, market: market)}
  def handle_async(:market, _unavailable, socket), do: {:noreply, socket}

  def render(%{status: :sign_in_required} = assigns) do
    ~H"""
    <main class="memestock">
      <Templates.header />
      <section id="autolaunch-stocks-create-sign-in" class="autolaunch-empty memestock__sign-in">
        <h2>Sign in to launch a memestock</h2>
        <p>
          A launch starts as a private draft saved to your account, so you need to be signed in.
          Once you are, you come straight back here.
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

  defp handle_stocks_image_progress(:stocks_image, entry, socket) do
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
      {:noreply,
       socket
       |> assign_draft(stored.draft)
       |> assign(draft_errors: %{}, image_notice: nil)}
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

  # A draft last saved before the account's newest Memestake auction was
  # launched as that auction, so it starts over; while that auction is still
  # live the form stays locked.
  defp load_draft(socket, %Human{human_account_id: id} = actor) do
    with {:ok, auction} <- Autolaunch.latest_memestake_auction(id),
         {:ok, draft} <- current_or_new_draft(actor),
         {:ok, draft} <- start_over_after(draft, auction, actor) do
      socket
      |> assign_draft(draft)
      |> assign(live_memestake?: live?(auction))
    else
      {:error, _error} -> assign(socket, status: :error)
    end
  end

  defp start_over_after(draft, %{inserted_at: launched_at}, actor) do
    if DateTime.before?(draft.updated_at, launched_at),
      do: Autolaunch.clear_stocks_launch_draft(draft, actor: actor),
      else: {:ok, draft}
  end

  defp start_over_after(draft, nil, _actor), do: {:ok, draft}

  defp live?(%{state: state}), do: state in [:created, :active]
  defp live?(nil), do: false

  # A link can name the stock (`?token=<symbol or address>`): the choice is
  # saved to the draft exactly as choosing it in the form would be, and a name
  # the draft's chain does not list leaves the draft as it was.
  defp choose_linked_stock(%{assigns: %{draft: %{} = draft}} = socket, token, actor)
       when is_binary(token) do
    with {:ok, stock} <- Stocks.Assets.named(draft.chain, token),
         false <- Address.equal?(draft.stock_address, stock.address),
         {:ok, saved} <-
           Autolaunch.autosave_stocks_terms(draft, %{"stock_address" => stock.address},
             actor: actor
           ) do
      assign_draft(socket, saved)
    else
      _unchanged -> socket
    end
  end

  defp choose_linked_stock(socket, _token, _actor), do: socket

  defp assign_draft(socket, draft) do
    assign(socket,
      draft: draft,
      draft_values: Templates.draft_values(draft),
      launch_chain: draft.chain,
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

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil
end
