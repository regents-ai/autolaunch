defmodule AutolaunchWeb.ProfileLive do
  @moduledoc """
  `/profile`: the signed-in person's account on Autolaunch: who is signed in,
  with which wallet, their connected accounts and a way to log out, plus the
  way to their Regents account, where pairings with agents are managed. The
  connected accounts reuse the Create page's connections component, so an
  account connected here is the same one Create shows.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.AccessContext

  @regents_account_url "https://regents.sh/account"

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/profile"))
     |> assign(
       current_human_id: current_human_id(socket.assigns.access_context),
       account: AccessContext.account_control(socket.assigns.access_context),
       regents_account_url: @regents_account_url
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "profile-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel autolaunch-heading" aria-label="Profile">
        <h1>Profile</h1>
        <p :if={!@current_human_id}>Sign in to see your account.</p>
        <Regent.Primitives.button
          :if={!@current_human_id}
          type="button"
          class="autolaunch-profile-page__sign-in"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
        <dl :if={@current_human_id} class="autolaunch-account">
          <dt>Signed in as</dt>
          <dd>{@account.label}</dd>
          <dt>Wallet</dt>
          <dd>{@account.wallet_address}</dd>
        </dl>
        <p :if={@current_human_id}>Manage your account and agent pairings on regents.sh</p>
        <div :if={@current_human_id} class="autolaunch-account__actions">
          <a
            class="rg-button rg-button--primary"
            href={@regents_account_url}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Go to Account on regents.sh, opens in a new tab"
          >
            Go to Account <span aria-hidden="true">↗</span>
          </a>
          <Regent.Primitives.button
            type="button"
            variant="secondary"
            data-account-target="sign-out"
          >
            Log out
          </Regent.Primitives.button>
        </div>
      </section>
      <.live_component
        :if={@current_human_id}
        module={AutolaunchWeb.CreatorConnectionsComponent}
        id="profile-connections"
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </section>
    """
  end
end
