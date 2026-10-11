defmodule AutolaunchWeb.AccountLive do
  @moduledoc """
  `/account`: the signed-in person's Account on Autolaunch. Signed out, it shows
  the shared signed-out section with the site's own Sign in button. Signed in,
  its Profile section says who is signed in, with which wallet, links to their
  Regents account, where pairings with agents are managed, and offers Sign out;
  their connected accounts follow. The connected accounts reuse the Create
  page's connections component, so an account connected here is the same one
  Create shows.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.AccessContext

  @regents_account_url "https://regents.sh/account"

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/account"))
     |> assign(
       current_human_id: current_human_id(socket.assigns.access_context),
       account: AccessContext.account_control(socket.assigns.access_context),
       regents_account_url: @regents_account_url
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "account-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <article class="autolaunch-account-page">
      <header class="autolaunch-heading">
        <h1>Account</h1>
      </header>
      <Regent.Account.signed_out :if={!@current_human_id} id="account-signed-out">
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <section
        :if={@current_human_id}
        class="market-profile-panel autolaunch-account-profile"
        aria-labelledby="account-profile-title"
      >
        <h2 id="account-profile-title">Profile</h2>
        <dl class="autolaunch-account">
          <dt>Signed in as</dt>
          <dd>{@account.label}</dd>
          <dt>Wallet</dt>
          <dd>{@account.wallet_address}</dd>
        </dl>
        <p>Manage your account and agent pairings on regents.sh</p>
        <div class="autolaunch-account__actions">
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
            Sign out
          </Regent.Primitives.button>
        </div>
      </section>
      <.live_component
        :if={@current_human_id}
        module={AutolaunchWeb.CreatorConnectionsComponent}
        id="account-connections"
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </article>
    """
  end
end
