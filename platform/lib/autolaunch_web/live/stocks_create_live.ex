defmodule AutolaunchWeb.StocksCreateLive do
  @moduledoc """
  Launch memestock, at /create: one form for the account's one Memestake
  draft. The Base and Robinhood switch moves the draft between chains; every
  field autosaves.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.
  """

  use AutolaunchWeb, :live_view

  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks
  alias Autolaunch.Stocks.{LaunchDraft, LaunchDraftImageStorage}
  alias AutolaunchWeb.Live.StocksCreateLive.Templates

  import AutolaunchWeb.Components.DraftCarryOver, only: [keep_draft: 2]

  @autosave_events ~w(autosave_stocks_token_details autosave_stocks_terms)
  @actions %{
    "autosave_stocks_token_details" => :autosave_token_details,
    "autosave_stocks_terms" => :autosave_terms
  }
  @chains %{"base" => :base, "robinhood" => :robinhood}

  # A completed sign-in reloads this route, so a signed-out visitor comes back
  # to the same page, now with their account's draft.
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        launch_chain: :base,
        linked_token: params["token"],
        draft: nil,
        draft_values: Templates.blank_draft_fields(),
        draft_errors: %{},
        draft_notice: nil,
        image_notice: nil,
        current_human_id: nil,
        stocks_lab: stocks_lab(),
        market: %{prices: %{}, venues: []},
        live_memestake?: false,
        status: :loading
      )

    case human_actor(socket) do
      nil ->
        socket = assign_sketch(socket, %LaunchDraft{})

        {:ok,
         if connected?(socket) do
           socket
           |> choose_linked_stock()
           |> assign_market()
         else
           socket
         end}

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
          |> assign(current_human_id: actor.human_account_id)

        {:ok,
         if connected?(socket) do
           socket
           |> load_draft(actor)
           |> choose_linked_stock()
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
    stock = chosen_stock(chain, socket.assigns.draft_values["stock_address"])
    start_async(socket, :market, fn -> Stocks.MarketData.overview(chain, stock) end)
  end

  defp chosen_stock(_chain, ""), do: nil

  defp chosen_stock(chain, address) do
    case Stocks.Assets.named(chain, address) do
      {:ok, stock} -> stock
      :error -> nil
    end
  end

  defp refresh_market(%{assigns: %{draft_values: %{"stock_address" => same}}} = socket, same),
    do: socket

  defp refresh_market(socket, _before), do: assign_market(socket)

  def handle_event(event, params, socket) when event in @autosave_events do
    values = Map.take(params["stock_draft"] || %{}, Templates.section_params(event))
    before = socket.assigns.draft_values["stock_address"]

    socket =
      case save_section(socket, event, values) do
        {:ok, socket} ->
          socket
          |> refresh_market(before)
          |> assign(draft_errors: %{}, draft_notice: saved_notice(socket))

        {:error, errors} ->
          assign(socket,
            draft_values: Map.merge(socket.assigns.draft_values, values),
            draft_errors: errors,
            draft_notice: unsaved_notice(socket)
          )
      end

    {:noreply, keep(socket)}
  end

  def handle_event("choose_chain", %{"chain" => chain}, socket) when is_map_key(@chains, chain) do
    chain = Map.fetch!(@chains, chain)

    if chain == socket.assigns.launch_chain do
      {:noreply, socket}
    else
      case switch_chain(socket, chain) do
        {:ok, socket} ->
          {:noreply,
           socket
           |> assign(draft_errors: %{}, draft_notice: nil, market: %{prices: %{}, venues: []})
           |> assign_market()
           |> keep()}

        :error ->
          {:noreply,
           assign(socket,
             draft_notice: %{tone: :error, message: "The chain could not be changed. Try again."}
           )}
      end
    end
  end

  # What a visitor typed while signed out, handed back by this tab. Signed in,
  # it goes into the account's draft through the same saves as typing it
  # would, except while the account's live auction keeps the form locked;
  # signed out, it refills the unsaved form after a reload.
  def handle_event("restore_draft", %{"values" => values}, socket) when is_map(values) do
    {:noreply, restore(socket, values)}
  end

  # The X connect button reloads the socials panel once the account is linked.
  def handle_event("refresh_x_connections", _params, %{assigns: %{current_human_id: id}} = socket)
      when is_integer(id) do
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

  def render(assigns) do
    assigns = assign(assigns, :stocks_image_upload, assigns[:uploads][:stocks_image])
    Templates.create(assigns)
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
        with {:ok, draft} <- current_or_new_draft(actor),
             {:ok, saved} <- autosave(event, draft, values, actor) do
          {:ok, assign_draft(socket, saved)}
        else
          error -> {:error, draft_field_errors(error)}
        end
    end
  end

  defp switch_chain(socket, chain) do
    result =
      case human_actor(socket) do
        nil ->
          with {:ok, sketch} <- sketch(socket.assigns.sketch, :choose_chain, %{chain: chain}),
               do: {:ok, assign_sketch(socket, sketch)}

        actor ->
          with {:ok, draft} <- current_or_new_draft(actor),
               {:ok, saved} <- Autolaunch.choose_stocks_launch_chain(draft, chain, actor: actor),
               do: {:ok, assign_draft(socket, saved)}
      end

    with {:error, _error} <- result, do: :error
  end

  defp saved_notice(%{assigns: %{current_human_id: nil}}), do: nil
  defp saved_notice(_socket), do: %{tone: :success, message: "Saved"}

  defp unsaved_notice(%{assigns: %{current_human_id: nil}}), do: nil

  defp unsaved_notice(_socket),
    do: %{tone: :error, message: "That change could not be saved. Check the marked field."}

  defp restore(%{assigns: %{live_memestake?: true}} = socket, _values), do: socket
  defp restore(%{assigns: %{status: :error}} = socket, _values), do: socket

  defp restore(socket, values) do
    values = Map.filter(values, fn {_param, value} -> is_binary(value) end)
    {socket, values} = restore_chain(socket, values)

    {socket, unsaved, errors} =
      Enum.reduce(@autosave_events, {socket, %{}, %{}}, &restore_section(&1, &2, values))

    socket
    |> assign(
      draft_values: Map.merge(socket.assigns.draft_values, unsaved),
      draft_errors: errors,
      draft_notice: if(unsaved == %{}, do: saved_notice(socket), else: unsaved_notice(socket))
    )
    |> choose_linked_stock()
    |> assign_market()
    |> keep()
  end

  # The stock and its amounts belong to the chain they were chosen on, so
  # they come across only once the draft is on that chain.
  defp restore_chain(socket, values) do
    case Map.fetch(@chains, values["chain"]) do
      {:ok, chain} when chain != socket.assigns.launch_chain ->
        case switch_chain(socket, chain) do
          {:ok, switched} -> {switched, values}
          :error -> {socket, Map.drop(values, Templates.section_params("autosave_stocks_terms"))}
        end

      _same_chain ->
        {socket, values}
    end
  end

  # A section that cannot be saved stays on the form as typed, marked.
  defp restore_section(event, {socket, unsaved, errors} = restored, values) do
    case Map.take(values, Templates.section_params(event)) do
      section when map_size(section) == 0 ->
        restored

      section ->
        case save_section(socket, event, section) do
          {:ok, socket} -> {socket, unsaved, errors}
          {:error, marked} -> {socket, Map.merge(unsaved, section), Map.merge(errors, marked)}
        end
    end
  end

  # Signed out, this tab keeps whatever differs from a new draft. The chain
  # comes too whenever it was switched or a stock was chosen, since a stock
  # belongs to its chain.
  defp keep(%{assigns: %{current_human_id: nil}} = socket) do
    fresh = Templates.draft_values(%LaunchDraft{})

    values =
      Map.reject(socket.assigns.draft_values, fn {param, value} -> fresh[param] == value end)

    values =
      if socket.assigns.launch_chain != :base or Map.has_key?(values, "stock_address"),
        do: Map.put(values, "chain", socket.assigns.launch_chain),
        else: values

    keep_draft(socket, values)
  end

  defp keep(socket), do: socket

  defp sketch(draft, action, values) do
    case draft |> Ash.Changeset.for_update(action, values) |> Ash.Changeset.apply_attributes() do
      {:ok, sketch} -> {:ok, sketch}
      {:error, changeset} -> {:error, Ash.Error.to_error_class(changeset.errors)}
    end
  end

  defp assign_sketch(socket, sketch) do
    assign(socket,
      sketch: sketch,
      draft_values: Templates.draft_values(sketch),
      launch_chain: sketch.chain,
      status: :ready
    )
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
  # made exactly as choosing it in the form would make it, and a name the
  # draft's chain does not list leaves the draft as it was. The link wins over
  # a stock this tab carried over.
  defp choose_linked_stock(%{assigns: %{status: :ready, linked_token: token}} = socket)
       when is_binary(token) do
    with {:ok, stock} <- Stocks.Assets.named(socket.assigns.launch_chain, token),
         false <- Address.equal?(socket.assigns.draft_values["stock_address"], stock.address),
         {:ok, socket} <-
           save_section(socket, "autosave_stocks_terms", %{"stock_address" => stock.address}) do
      keep(socket)
    else
      _unchanged -> socket
    end
  end

  defp choose_linked_stock(socket), do: socket

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
