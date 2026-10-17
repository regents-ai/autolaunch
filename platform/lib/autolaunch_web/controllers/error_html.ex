defmodule AutolaunchWeb.ErrorHTML do
  @moduledoc "Standalone HTML errors use the same product sheet without starting session UI."
  use AutolaunchWeb, :html

  def render(template, assigns) do
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(
        message: headline(template),
        retry?: String.starts_with?(template, "503"),
        theme: AutolaunchWeb.Plugs.Theme.read(assigns.conn)
      )

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-brand="autolaunch" data-theme={@theme}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="color-scheme" content={@theme || "dark light"} />
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
              <%= if @retry? do %>
                <p>It could not be read just now. Try again in a moment.</p>
                <div class="autolaunch-error__actions">
                  <a
                    href={Phoenix.Controller.current_path(@conn)}
                    class="rg-button rg-button--primary"
                  ><span class="rg-button__label">Try again</span></a>
                  <a href="/" class="rg-button rg-button--secondary"><span class="rg-button__label">Return to Autolaunch</span></a>
                </div>
              <% else %>
                <p>This page could not be displayed. Return to the market to continue.</p>
                <a href="/" class="rg-button rg-button--primary"><span class="rg-button__label">Return to Autolaunch</span></a>
              <% end %>
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
  defp headline("503" <> _format), do: "This page didn’t open"
  defp headline(_template), do: "Something went wrong"
end
