defmodule AutolaunchWeb.Components.AgentTools do
  @moduledoc """
  The WebMCP tools every page offers an agent, read when this module compiles
  from `priv/tool_manifest.json`, the file the pages register them from
  (`assets/js/public_tools.ts` offers the entries scoped to the site). The
  button under the top bar (on a phone, in the footer) says how many there are and opens a dialog listing
  each tool with its description, which copies the whole list as Markdown.

  The same component as ash-template's (64bd92c), with one addition the
  template can take back: the dialog's optional `intro` slot, shown above the
  list, which here says what WebMCP is and gives a prompt to copy for an agent.
  """

  use Phoenix.Component

  manifest = Application.app_dir(:autolaunch, "priv/tool_manifest.json")
  @external_resource manifest

  @tools (for %{"scope" => "site"} = tool <-
                manifest |> File.read!() |> Jason.decode!() |> Map.fetch!("tools") do
            %{name: tool["name"], title: tool["title"], description: tool["description"]}
          end)

  @label "#{length(@tools)} Agent Tools"

  @markdown """
  # Autolaunch: #{@label}

  #{Enum.map_join(@tools, "\n\n", &"## #{&1.title}\n\n`#{&1.name}`\n\n#{&1.description}")}
  """

  attr :id, :string, required: true
  attr :dialog, :string, required: true, doc: "The id of the `dialog/1` it opens."

  @doc """
  The button naming how many tools agents see, which opens their list.
  """
  def button(assigns) do
    assigns = assign(assigns, label: @label)

    ~H"""
    <button
      id={@id}
      class="agent-tools-button"
      type="button"
      aria-haspopup="dialog"
      aria-controls={@dialog}
      data-agent-tools-open
    >
      {@label}
    </button>
    """
  end

  attr :id, :string, required: true

  slot :intro, doc: "A few lines above the list, such as what WebMCP is and a prompt to copy."

  @doc "The dialog listing every tool, closed with its X, Escape or a press beside it."
  def dialog(assigns) do
    assigns = assign(assigns, label: @label, tools: @tools, markdown: @markdown)

    ~H"""
    <dialog
      id={@id}
      class="code-card agent-tools"
      aria-labelledby={"#{@id}-title"}
      data-agent-tools
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <header class="code-card__head">
        <h2 id={"#{@id}-title"}>{@label}</h2>
        <div class="code-card__copy">
          <Regent.Primitives.copy_button id={"#{@id}-copy"} text={@markdown}>
            Copy as Markdown
          </Regent.Primitives.copy_button>
        </div>
        <button type="button" class="code-card__close" aria-label="Close" data-agent-tools-close>
          <svg viewBox="0 0 16 16" aria-hidden="true">
            <path d="M3 3l10 10M13 3L3 13" fill="none" stroke="currentColor" stroke-width="1.5" />
          </svg>
        </button>
      </header>
      <div class="code-card__body">
        <div :for={intro <- @intro} class="agent-tools__intro">{render_slot(intro)}</div>
        <ol class="code-card__list">
          <li :for={tool <- @tools} class="code-card__tool">
            <h3>{tool.title}</h3>
            <code>{tool.name}</code>
            <p>{tool.description}</p>
          </li>
        </ol>
      </div>
    </dialog>
    """
  end
end
