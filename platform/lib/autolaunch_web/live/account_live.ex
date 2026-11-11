defmodule AutolaunchWeb.AccountLive do
  @moduledoc """
  `/account`: the signed-in person's Account on Autolaunch, in the layout every Regent
  site shares (`Regent.Account.layout`) with this site's own sections first. Signed
  out, it shows the shared signed-out section with the site's own Sign in button, and
  says the sign-in ended when it lapsed while the page was open. Signed in, this
  site's own section comes first: the accounts they connected, through the Create
  page's connections component, so an account connected here is the same one
  Create shows. Then the shared sections: who is signed in with which wallet, and
  the name people see for them. The agents have their own page
  (`AutolaunchWeb.AccountAgentsLive`), and so do Points (`AutolaunchWeb.PointsLive`).
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  def mount(_params, _session, socket),
    do: {:ok, assign(socket, AutolaunchWeb.PublicDocuments.page("/account"))}

  # The name was saved from the browser. The session hook reads the account again
  # before this event (`AutolaunchWeb.Live.Session`), so the page already shows the
  # new name everywhere it appears.
  def handle_event("public_name_saved", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "account-connections",
      current_human_id: current_human_id(socket.assigns.access_context),
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    assigns = assign(assigns, :current_human_id, current_human_id(assigns.access_context))

    ~H"""
    <article class="autolaunch-account-page">
      <header class="autolaunch-heading">
        <h1>Account</h1>
      </header>
      <Regent.Account.signed_out
        :if={!@current_human_id}
        id="account-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <Regent.Account.layout :if={@current_human_id} id="account">
        <:site>
          <.live_component
            module={AutolaunchWeb.CreatorConnectionsComponent}
            id="account-connections"
            current_human_id={@current_human_id}
            session_lease={@session_lease}
          />
        </:site>
        <:identity>
          <Regent.Account.identity
            id="account-identity"
            name={@account_control.label}
            wallet={@account_control.wallet_address}
            ens_name={@account_control.ens_name}
          >
            <:picture>
              <img
                :if={@account_control.avatar_src}
                src={@account_control.avatar_src}
                referrerpolicy="no-referrer"
                width="64"
                height="64"
                alt=""
              />
            </:picture>
          </Regent.Account.identity>
        </:identity>
        <:profile>
          <%!-- The name is saved from the browser with the sign-in's own proof. --%>
          <div id="account-profile" phx-hook="PublicName" phx-update="ignore">
            <Regent.Profile.panel
              id="account-public-name"
              display_name={signed_in_account(@access_context).display_name}
            />
          </div>
        </:profile>
      </Regent.Account.layout>
    </article>
    """
  end

  defp signed_in_account(%{principal: {:human, account}}), do: account
end
