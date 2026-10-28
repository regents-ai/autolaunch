defmodule AutolaunchWeb.StocksCreateLive do
  @moduledoc """
  Create a Memestock token, at /create: one form for the account's one Memestock
  draft. The Base and Robinhood switch moves the draft between chains; every
  field autosaves.

  A signed-out visitor explores the same form against an unsaved draft that
  follows the saved draft's rules. This browser tab keeps what they typed, and
  once they sign in it is saved into their account's draft.
  """

  use AutolaunchWeb, :live_view

  require Logger

  alias Autolaunch.Actors.Human
  alias Autolaunch.{AgentDrafts, ImageColor, Listings, Stocks, Ticker}
  alias Autolaunch.Stocks.{LaunchDraft, LaunchDraftImageStorage}
  alias AutolaunchWeb.Components.{AutolaunchHelpers, StockSelect}
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.Live.StocksCreateLive.Templates
  alias AutolaunchWeb.ReadFailure
  alias RegentChain.Address

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
      socket
      |> assign(AutolaunchWeb.PublicDocuments.page("/create"))
      |> assign(
        launch_chain: :base,
        linked_token: params["token"],
        draft: nil,
        draft_values: Templates.blank_draft_fields(),
        draft_errors: %{},
        draft_notice: nil,
        image_notice: nil,
        image_color: nil,
        current_human_id: nil,
        creator_connections: %{},
        market: %{prices: %{}, venues: []},
        stock_sort: "alphabetical",
        reviewing?: false,
        launched?: false,
        listings: 0,
        ticker_taken?: false,
        status: :loading
      )
      |> assign_stocks()

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
           Listings.subscribe()
           AgentDrafts.subscribe("memestock", actor.human_account_id)

           socket
           |> load_draft(actor)
           |> assign_connections()
           |> choose_linked_stock()
           |> assign_market()
           |> assign_ticker_taken()
         else
           socket
         end}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # The accounts the creator has connected and proved, as a listed auction's
  # gallery card shows them, for the card's preview.
  defp assign_connections(%{assigns: %{current_human_id: id}} = socket) do
    creator = %{creator_human_account_id: id}

    assign(socket,
      creator_connections:
        AutolaunchHelpers.connections_for(
          creator,
          AutolaunchHelpers.creator_connections_for([creator])
        )
    )
  end

  # The chain's stock prices and the chosen stock's venues are read in the
  # background: the page renders without them and fills them in when they land.
  defp assign_market(socket) do
    chain = socket.assigns.launch_chain
    stock = chosen_stock(socket.assigns.stocks, socket.assigns.draft_values["stock_address"])
    start_async(socket, :market, fn -> Stocks.MarketData.overview(chain, stock) end)
  end

  defp chosen_stock(:unread, _address), do: nil
  defp chosen_stock(_stocks, ""), do: nil

  defp chosen_stock(stocks, address) do
    case Stocks.Assets.named(stocks, address) do
      {:ok, stock} -> stock
      :error -> nil
    end
  end

  # The draft's chain's stock list, read again each time the draft is, or
  # `:unread` when it couldn't be read: the picker then says so, with Try
  # again. A failed read is logged by kind and module only.
  defp assign_stocks(socket) do
    stocks =
      case Stocks.Assets.read(socket.assigns.launch_chain) do
        {:ok, stocks} ->
          stocks

        {:error, error} ->
          ReadFailure.log("stock list read", error)
          :unread
      end

    assign(socket, stocks: stocks)
  end

  defp refresh_market(%{assigns: %{draft_values: %{"stock_address" => same}}} = socket, same),
    do: socket

  # Another stock's venues are not this one's, so they come down at once.
  defp refresh_market(socket, _before),
    do: socket |> assign(:market, %{socket.assigns.market | venues: []}) |> assign_market()

  def handle_event(event, params, socket) when event in @autosave_events do
    values = Map.take(params["stock_draft"] || %{}, Templates.section_params(event))
    {:noreply, autosaved(socket, event, values)}
  end

  def handle_event("read_stocks", _params, socket),
    do: {:noreply, socket |> assign_stocks() |> assign_market()}

  def handle_event("sort_stocks", %{"by" => by}, socket) do
    if by in StockSelect.sorts(),
      do: {:noreply, assign(socket, :stock_sort, by)},
      else: {:noreply, socket}
  end

  def handle_event("choose_chain", %{"chain" => chain}, socket) when is_map_key(@chains, chain) do
    case chosen_chain(socket, Map.fetch!(@chains, chain)) do
      {:ok, socket} ->
        {:noreply, socket}

      :error ->
        {:noreply,
         assign(socket,
           draft_notice: %{tone: :error, message: "The chain could not be changed. Try again."}
         )}
    end
  end

  # What a visitor typed while signed out, handed back by this tab. Signed in,
  # it goes into the account's draft through the same saves as typing it
  # would; signed out, it refills the unsaved form after a reload. When the
  # draft could not be read, nothing is taken and the tab keeps the values for
  # a later visit.
  def handle_event("restore_draft", %{"values" => values}, socket) when is_map(values) do
    if taken?(socket),
      do: {:reply, %{taken: true}, restore(socket, values)},
      else: {:reply, %{taken: false}, socket}
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

  # A launch card opened its review: the details lock so the review always
  # matches them, and the saved note no longer describes what this page is
  # doing and comes down. Once the review closes they open again, read anew,
  # blank when the launch was listed. A launch just made keeps its card, which
  # says so, until the person dismisses it.
  def handle_info({:launch_review, :open}, socket),
    do: {:noreply, assign(socket, reviewing?: true, draft_notice: nil)}

  def handle_info({:launch_review, news}, socket) when news in [:closed, :launched] do
    socket = assign(socket, reviewing?: false, launched?: news == :launched)

    case human_actor(socket) do
      nil -> {:noreply, socket}
      actor -> {:noreply, socket |> load_draft(actor) |> assign_ticker_taken()}
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
  def handle_info({:agent_draft_saved, "memestock"}, %{assigns: %{reviewing?: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:agent_draft_saved, "memestock"}, socket) do
    unsaved = Map.take(socket.assigns.draft_values, Map.keys(socket.assigns.draft_errors))

    case saved_draft(human_actor(socket)) do
      {:ok, draft} ->
        socket = assign_draft(socket, draft)

        {:noreply,
         socket
         |> assign(draft_values: Map.merge(socket.assigns.draft_values, unsaved))
         |> assign_ticker_taken()}

      {:error, _error} ->
        {:noreply, socket}
    end
  end

  def handle_async(:market, {:ok, market}, socket), do: {:noreply, assign(socket, market: market)}
  def handle_async(:market, _unavailable, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns = assign(assigns, :stocks_image_upload, assigns[:uploads][:stocks_image])
    Templates.create(assigns)
  end

  # One section of the form saved as typing it would save it.
  defp autosaved(socket, event, values) do
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
            draft_notice: unsaved_notice(socket, errors)
          )
      end

    socket |> assign_ticker_taken() |> keep()
  end

  defp chosen_chain(%{assigns: %{launch_chain: chain}} = socket, chain), do: {:ok, socket}

  defp chosen_chain(socket, chain) do
    with {:ok, socket} <- switch_chain(socket, chain) do
      {:ok,
       socket
       |> assign(draft_errors: %{}, draft_notice: nil, market: %{prices: %{}, venues: []})
       |> assign_market()
       |> keep()}
    end
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
        case save_draft(socket, actor, &autosave(event, &1, values, actor)) do
          {:ok, saved} -> {:ok, assign_draft(socket, saved)}
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
          with {:ok, saved} <-
                 save_draft(
                   socket,
                   actor,
                   &Autolaunch.choose_stocks_launch_chain(&1, chain, actor: actor)
                 ),
               do: {:ok, assign_draft(socket, saved)}
      end

    with {:error, _error} <- result, do: :error
  end

  defp saved_notice(%{assigns: %{current_human_id: nil}}), do: nil
  defp saved_notice(_socket), do: %{tone: :success, message: "Saved"}

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

  defp taken?(%{assigns: %{status: status}}), do: status != :error

  defp restore(socket, values) do
    values = Map.filter(values, fn {_param, value} -> is_binary(value) end)
    {socket, values} = restore_chain(socket, values)

    {socket, unsaved, errors} =
      Enum.reduce(@autosave_events, {socket, %{}, %{}}, &restore_section(&1, &2, values))

    socket
    |> assign(
      draft_values: Map.merge(socket.assigns.draft_values, unsaved),
      draft_errors: errors,
      draft_notice:
        if(unsaved == %{}, do: saved_notice(socket), else: unsaved_notice(socket, errors))
    )
    |> choose_linked_stock()
    |> assign_market()
    |> assign_ticker_taken()
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
    socket
    |> assign(
      sketch: sketch,
      draft_values: Templates.draft_values(sketch),
      launch_chain: sketch.chain,
      status: :ready
    )
    |> assign_stocks()
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
         {:ok, stored} <- attach_image(socket, actor, bytes, entry) do
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

  # A listed launch's draft was already started over
  # (`Autolaunch.LaunchedDrafts`).
  defp load_draft(socket, %Human{} = actor) do
    case current_or_new_draft(socket, actor) do
      {:ok, draft} -> assign_draft(socket, draft)
      {:error, _error} -> assign(socket, status: :error)
    end
  end

  # A link can name the stock (`?token=<symbol or address>`): the choice is
  # made exactly as choosing it in the form would make it, and a name the
  # draft's chain does not list leaves the draft as it was. The link wins over
  # a stock this tab carried over.
  defp choose_linked_stock(%{assigns: %{status: :ready, linked_token: token}} = socket)
       when is_binary(token) do
    with stocks when is_list(stocks) <- socket.assigns.stocks,
         {:ok, stock} <- Stocks.Assets.named(stocks, token),
         false <- Address.equal?(socket.assigns.draft_values["stock_address"], stock.address),
         {:ok, socket} <-
           save_section(socket, "autosave_stocks_terms", %{"stock_address" => stock.address}) do
      keep(socket)
    else
      _unchanged -> socket
    end
  end

  defp choose_linked_stock(socket), do: socket

  defp assign_ticker_taken(socket),
    do: assign(socket, ticker_taken?: Ticker.taken?(socket.assigns.draft_values["symbol"]))

  defp assign_draft(socket, draft) do
    socket
    |> assign_image_color(draft.image)
    |> assign(
      draft: draft,
      draft_values: Templates.draft_values(draft),
      launch_chain: draft.chain,
      status: :ready
    )
    |> assign_stocks()
  end

  # The colour the gallery tints the auction's card with, read again only when
  # the draft's image changes.
  defp assign_image_color(%{assigns: %{draft: %{image: image}}} = socket, image),
    do: socket

  defp assign_image_color(socket, image),
    do: assign(socket, image_color: ImageColor.for_url(image))

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

  # The account's draft; a first one is made only under the page's lease read
  # again now, like every other draft write.
  defp current_or_new_draft(socket, actor) do
    case Autolaunch.get_my_stocks_launch_draft(actor: actor) do
      {:ok, nil} -> Session.transact(socket, fn -> found_or_new_draft(actor) end)
      read -> read
    end
  end

  # Only ever run inside `Session.transact/2`.
  defp found_or_new_draft(actor) do
    case Autolaunch.get_my_stocks_launch_draft(actor: actor) do
      {:ok, nil} -> Autolaunch.create_stocks_launch_draft(%{}, actor: actor)
      read -> read
    end
  end

  # The draft the person's agent just saved, read only: it exists already.
  defp saved_draft(actor) do
    case Autolaunch.get_my_stocks_launch_draft(actor: actor) do
      {:ok, nil} -> {:error, :draft_missing}
      read -> read
    end
  end

  defp draft_field_errors({:error, %Ash.Error.Invalid{errors: errors}} = failure) do
    params = Templates.draft_field_params()

    marked =
      for %{field: field} = error <- errors,
          to_string(field) in params,
          into: %{},
          do: {to_string(field), error_message(error)}

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

  defp error_message(%Ash.Error.Changes.Required{}), do: "Fill this in."
  defp error_message(%{message: message}), do: message

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil
end
