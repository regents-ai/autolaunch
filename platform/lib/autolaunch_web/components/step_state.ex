defmodule AutolaunchWeb.Components.StepState do
  @moduledoc """
  Where one wallet step stands, as a status chip whose colour follows the
  word: waiting steps stay plain, ready and sent ones read as information, an
  unresolved one asks for attention, a finished one reads as done and a
  reverted one as an error.
  """
  use Phoenix.Component

  @tones %{
    "Ready" => "info",
    "Sent" => "info",
    "Confirmed" => "success",
    "Reverted" => "error",
    "Unresolved" => "warning"
  }

  attr :state, :string, required: true

  def step_state(assigns) do
    assigns = assign(assigns, :tone, Map.get(@tones, assigns.state, "neutral"))

    ~H"""
    <Regent.Primitives.status tone={@tone}>{@state}</Regent.Primitives.status>
    """
  end
end
