defmodule AutolaunchWeb.Components.ChainIcon do
  @moduledoc """
  A chain's small mark beside text: Base's blue square and Robinhood's
  feather, both from the chains' own brand kits. The feather takes the text
  colour, so it reads in light and dark.
  """
  use Phoenix.Component

  attr :chain, :atom, required: true, values: [:base, :robinhood]
  attr :class, :any, default: nil

  def chain_icon(%{chain: :base} = assigns) do
    ~H"""
    <svg
      class={["chain-icon", @class]}
      viewBox="0 0 1280 1280"
      role="img"
      aria-label="Base"
      focusable="false"
    >
      <path
        fill="#0000ff"
        d="M0,101.12c0-34.64,0-51.95,6.53-65.28,6.25-12.76,16.56-23.07,29.32-29.32C49.17,0,66.48,0,101.12,0h1077.76c34.63,0,51.96,0,65.28,6.53,12.75,6.25,23.06,16.56,29.32,29.32,6.52,13.32,6.52,30.64,6.52,65.28v1077.76c0,34.63,0,51.96-6.52,65.28-6.26,12.75-16.57,23.06-29.32,29.32-13.32,6.52-30.65,6.52-65.28,6.52H101.12c-34.64,0-51.95,0-65.28-6.52-12.76-6.26-23.07-16.57-29.32-29.32-6.53-13.32-6.53-30.65-6.53-65.28V101.12Z"
      />
    </svg>
    """
  end

  def chain_icon(%{chain: :robinhood} = assigns) do
    ~H"""
    <svg
      class={["chain-icon", @class]}
      viewBox="0 0 160 207"
      role="img"
      aria-label="Robinhood Chain"
      focusable="false"
    >
      <path
        fill="currentColor"
        d="M102.68,48.62c-23.4,26.03-60.7,69.5-94.97,157.27-.41.69-1.1,1.11-1.93,1.11H1.24c-.96,0-1.51-.55-1.1-1.66,4.54-16.89,10.74-35.58,20.51-63.13v-38.21c0-7.34,1.1-12.46,5.51-18l30-37.38c.96-1.38,2.34-1.94,3.85-1.94h41.84c1.38,0,1.79.83.83,1.94ZM152.23,5.57c7.3,7.75,8.26,26.44,6.61,38.62-1.24,8.31-2.61,10.11-7.16,16.06l-27.94,36.69c-.83,1.25-1.93.83-1.93-.55v-52.61c0-4.29-2.48-6.78-6.74-6.78h-46.38c-1.38,0-1.79-.97-.83-1.94,7.85-8.31,16.1-16.75,28.49-27.41,2.75-2.49,4.13-2.77,6.74-4.01,13.49-5.26,42.67-4.98,49.14,1.94h0ZM112.04,58.03v52.88c0,.69-.14,1.66-.55,2.49l-19.13,31.7c-2.34,3.88-5.09,6.09-9.91,7.34l-42.94,13.29c-1.24.41-1.93-.42-1.38-1.52,20.78-40.84,43.22-74.76,71.98-107.01.96-1.11,1.93-.55,1.93.83h0Z"
      />
    </svg>
    """
  end
end
