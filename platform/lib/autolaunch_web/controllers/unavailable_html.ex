defmodule AutolaunchWeb.UnavailableHTML do
  use AutolaunchWeb, :html

  def show(assigns) do
    ~H"""
    <section id="unavailable" class="autolaunch-error rg-inset" aria-labelledby="unavailable-title">
      <Regent.Structure.section_bar>
        <h1 id="unavailable-title" class="rg-section-bar__label">Not available in your region</h1>
      </Regent.Structure.section_bar>
      <p>This page isn’t offered where you are. The rest of Autolaunch is open to you.</p>
      <a href="/" class="rg-button rg-button--primary">
        <span class="rg-button__label">Return to Autolaunch</span>
      </a>
    </section>
    """
  end
end
