defmodule AutolaunchWeb.SharedProfileHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <main class="autolaunch-profile-page" style="max-width: 42rem; margin: 2rem auto; padding: 1rem;">
      <Regent.Profile.panel />
    </main>
    """
  end
end
