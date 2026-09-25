defmodule AutolaunchWeb.Components.DraftCarryOver do
  @moduledoc """
  What a signed-out visitor types on a create page, kept by this browser tab
  until they sign in. Signed out, the page hands the tab its latest values
  after every change, and a reload fills the form from them again. Signed in,
  the tab hands them back once, as the `restore_draft` event, and forgets them.
  """
  use Phoenix.Component

  @doc "Hands this tab what a signed-out visitor has typed so far."
  def keep_draft(socket, values),
    do: Phoenix.LiveView.push_event(socket, "keep_draft", %{values: values})

  attr :id, :string, required: true
  attr :key, :string, required: true, doc: "the tab's name for this page's values"
  attr :signed_in, :boolean, required: true

  def draft_carry_over(assigns) do
    ~H"""
    <div
      id={@id}
      hidden
      phx-hook=".DraftCarryOver"
      data-key={@key}
      data-signed-in={to_string(@signed_in)}
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DraftCarryOver">
      export default {
        mounted() {
          const key = this.el.dataset.key
          const signedIn = this.el.dataset.signedIn === "true"
          let values = null

          try {
            values = JSON.parse(sessionStorage.getItem(key) ?? "null")
            if (signedIn) sessionStorage.removeItem(key)
          } catch {
            values = null
          }

          if (!signedIn) {
            this.handleEvent("keep_draft", ({values}) => {
              try {
                if (Object.keys(values).length === 0) sessionStorage.removeItem(key)
                else sessionStorage.setItem(key, JSON.stringify(values))
              } catch {
                // A tab that cannot keep values only loses the carry-over.
              }
            })
          }

          if (values && typeof values === "object" && Object.keys(values).length > 0) {
            this.pushEvent("restore_draft", {values})
          }
        }
      }
    </script>
    """
  end
end
