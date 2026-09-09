defmodule AutolaunchWeb.StocksCreateLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Actors.Human
  alias Autolaunch.Stocks
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
          assign(socket,
            draft: nil,
            draft_values: Templates.blank_draft_fields(),
            draft_errors: %{},
            draft_notice: nil,
            current_human_id: actor.human_account_id,
            stocks_lab: stocks_lab(),
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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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

  def render(assigns), do: Templates.create(assigns)

  defp autosave("autosave_stocks_token_details", draft, values, actor),
    do: Autolaunch.autosave_stocks_token_details(draft, values, actor: actor)

  defp autosave("autosave_stocks_terms", draft, values, actor),
    do: Autolaunch.autosave_stocks_terms(draft, values, actor: actor)

  defp autosave("autosave_stocks_revenue", draft, values, actor),
    do: Autolaunch.autosave_stocks_revenue(draft, values, actor: actor)

  defp load_draft(socket, actor) do
    case current_or_new_draft(actor) do
      {:ok, draft} -> socket |> assign_draft(draft) |> assign(status: :ready)
      {:error, _error} -> assign(socket, status: :error)
    end
  end

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

  defp human_actor(%{assigns: %{access_context: %{principal: {:human, %{id: id}}}}})
       when is_integer(id),
       do: %Human{human_account_id: id}

  defp human_actor(_socket), do: nil
end
