defmodule AutolaunchWeb.SubjectsLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(_params, _session, socket) do
    {:ok,
     assign_async(socket, [:records, :creators], fn -> read_index(&Autolaunch.list_subjects/0) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <section id="autolaunch-subjects" class="autolaunch-page">
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch</p>
        <h1>Subjects</h1>
        <p>Browse the people and projects that share launch revenue.</p>
      </header>
      <.empty_state
        :if={@records.ok? && @records.result == []}
        copy="No public subjects yet."
      />
      <.empty_state
        :if={@records.failed}
        copy="Public subjects are unavailable right now."
      />
      <ol :if={@records.ok? && @records.result != []} class="autolaunch-record-list">
        <li :for={subject <- @records.result}>
          <.link navigate={"/subjects/#{subject.subject_id}"}>
            <strong>{subject_label(subject)}</strong>
            <span>
              {display_text(subject.token_address)} · {display_text(subject.subject_kind)} · Chain {subject.chain_id}
            </span>
          </.link>
          <.treasury_security report={report(subject)} surface={"subject-#{subject.subject_id}"} />
        </li>
      </ol>
    </section>
    """
  end
end
