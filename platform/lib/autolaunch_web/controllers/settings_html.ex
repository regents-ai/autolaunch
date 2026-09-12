defmodule AutolaunchWeb.SettingsHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel autolaunch-heading" aria-label="Settings">
        <h1>Settings</h1>
        <p :if={@account_control.kind == :sign_in}>Sign in to see your account settings.</p>
        <Regent.Primitives.button
          :if={@account_control.kind == :sign_in}
          type="button"
          data-account-target="sign-in"
          disabled={Autolaunch.Prelaunch.read_only?()}
        >
          Sign in
        </Regent.Primitives.button>
        <dl :if={@account_control.kind == :signed_in} class="autolaunch-settings">
          <dt>Signed in as</dt>
          <dd>{@account_control.label}</dd>
          <dt>Wallet</dt>
          <dd>{@account_control.wallet_address}</dd>
        </dl>
        <p :if={@account_control.kind == :signed_in}>
          Your name, wallet choice and X connection live on your <.link href="/profile">profile</.link>. There is nothing else to set yet.
        </p>
        <Regent.Primitives.button
          :if={@account_control.kind == :signed_in}
          type="button"
          variant="secondary"
          class="autolaunch-settings__leave"
          data-account-target="sign-out"
          disabled={Autolaunch.Prelaunch.read_only?()}
        >
          Log out
        </Regent.Primitives.button>
      </section>
    </section>
    """
  end
end
