defmodule AutolaunchWeb.ErrorHTML do
  @moduledoc "Standalone HTML errors use the same product sheet without starting session UI."
  use AutolaunchWeb, :html

  def render(template, assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(:message, Phoenix.Controller.status_message_from_template(template))

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-brand="autolaunch" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="dark light" />
        <title>{@message} · Autolaunch</title>
        <link rel="icon" href={~p"/favicon.svg"} />
        <link rel="stylesheet" href={~p"/assets/js/app.css"} />
        <script>
          ((query) => {
            const follow = () => document.documentElement.setAttribute("data-theme", query.matches ? "light" : "dark")
            follow()
            query.addEventListener("change", follow)
          })(window.matchMedia("(prefers-color-scheme: light)"))
        </script>
      </head>
      <body>
        <AutolaunchWeb.Layouts.lab_notice />
        <Regent.Structure.frame>
          <Regent.Structure.row rail={false}>
            <header class="rg-inset rg-support-band">
              <a class="shell-wordmark" href="/">Autolaunch</a>
            </header>
          </Regent.Structure.row>
          <Regent.Structure.row rail={false}>
            <main class="autolaunch-error rg-inset">
              <Regent.Structure.section_bar>
                <h1 class="rg-section-bar__label">{@message}</h1>
              </Regent.Structure.section_bar>
              <p>This page could not be displayed. Return to the market to continue.</p>
              <a href="/" class="rg-button rg-button--primary"><span class="rg-button__label">Return to Autolaunch</span></a>
            </main>
          </Regent.Structure.row>
          <Regent.Structure.row rail={false}>
            <AutolaunchWeb.Layouts.product_links />
          </Regent.Structure.row>
        </Regent.Structure.frame>
      </body>
    </html>
    """
  end
end
