defmodule AutolaunchWeb.ErrorHTML do
  @moduledoc "Standalone HTML errors use the same product sheet without starting session UI."
  use AutolaunchWeb, :html

  def render(template, assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(message: headline(template), theme: AutolaunchWeb.Plugs.Theme.read(assigns.conn))

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-brand="autolaunch" data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content={@theme} />
        <title>{@message} · Autolaunch</title>
        <link rel="icon" href={~p"/favicon.svg"} />
        <link rel="stylesheet" href={~p"/assets/js/app.css"} />
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

  defp headline("404" <> _format), do: "We can’t find that page"
  defp headline(_template), do: "Something went wrong"
end
