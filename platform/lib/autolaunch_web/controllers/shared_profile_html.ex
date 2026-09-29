defmodule AutolaunchWeb.SharedProfileHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <main class="autolaunch-profile-page" >
      <Regent.Structure.section_bar class="rg-support-band">
        <p class="rg-section-bar__label">Your account</p>
      </Regent.Structure.section_bar>
      <Regent.Structure.panel class="rg-support-panel">
        <Regent.Profile.panel />
      </Regent.Structure.panel>
    </main>
    """
  end
end
