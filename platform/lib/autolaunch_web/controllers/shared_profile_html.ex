defmodule AutolaunchWeb.SharedProfileHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel" aria-label="Account details">
        <Regent.Profile.panel />
      </section>
    </section>
    """
  end
end
