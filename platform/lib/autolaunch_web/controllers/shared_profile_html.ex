defmodule AutolaunchWeb.SharedProfileHTML do
  use AutolaunchWeb, :html

  # A signed-out visitor gets a plain sign-in prompt; the profile panel only
  # renders once the site session names an account. Sign-in reloads the page.
  def show(%{account_control: %{kind: :sign_in}} = assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel autolaunch-heading" aria-label="Profile">
        <h1>Profile</h1>
        <p>Sign in to see your profile and connected accounts.</p>
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          Sign in
        </Regent.Primitives.button>
      </section>
    </section>
    """
  end

  def show(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel" aria-label="Account details">
        <Regent.Profile.panel />
      </section>
      {live_render(@conn, AutolaunchWeb.ProfileConnectionsLive,
        id: "profile-connections-live",
        session: AutolaunchWeb.Live.Session.render_context(@conn)
      )}
    </section>
    """
  end
end
