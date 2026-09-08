defmodule AutolaunchWeb.SharedProfileHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel" aria-label="Account details">
        <div :if={Autolaunch.Prelaunch.read_only?()} class="autolaunch-heading">
          <h1>Profile</h1>
          <p>Account changes are unavailable during prelaunch.</p>
          <Regent.Primitives.button disabled>Edit profile</Regent.Primitives.button>
          <Regent.Primitives.button disabled variant="secondary">Connect wallet</Regent.Primitives.button>
        </div>
        <Regent.Profile.panel :if={!Autolaunch.Prelaunch.read_only?()} />
      </section>
    </section>
    """
  end
end
