defmodule AutolaunchWeb.Components.AgentSetFields do
  @moduledoc """
  On both create pages, above the launch's wallet steps: every field the
  person's paired agent filled in and the person has not changed since, with
  its value, so nothing an agent chose reaches a wallet step unseen
  (`Autolaunch.AgentDrafts`). A field the person edits leaves the list.
  """
  use Phoenix.Component

  @labels %{
    name: "Name",
    symbol: "Ticker",
    description: "Description",
    website: "Website",
    telegram: "Telegram",
    discord: "Discord",
    other_link_1: "Link",
    other_link_2: "Link",
    other_link_3: "Link",
    image: "Picture",
    treasury: "Treasury address",
    treasury_path: "Treasury owner",
    chain: "Chain",
    stock_address: "Paired stock"
  }

  @paths %{safe: "A Safe", contract: "A smart contract account", eoa: "A private key (EOA)"}

  attr :draft, :map, required: true, doc: "the person's draft, Revstake or Memestock"

  def agent_set_fields(assigns) do
    assigns = assign(assigns, :rows, rows(assigns.draft))

    ~H"""
    <section
      :if={@rows != []}
      id="agent-set-fields"
      class="agent-set"
      aria-labelledby="agent-set-title"
    >
      <h3 id="agent-set-title">Your agent filled these in</h3>
      <p>Check each one before you launch. Change any of them above and it is yours.</p>
      <dl>
        <div :for={{label, value} <- @rows}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
    </section>
    """
  end

  @doc "The names of agent-set fields, as a launch review's facts list them."
  def labels(fields) when is_list(fields),
    do: fields |> Enum.map(&Map.fetch!(@labels, String.to_existing_atom(&1))) |> Enum.uniq()

  defp rows(%{agent_set_fields: fields} = draft) when is_list(fields),
    do: Enum.map(fields, &{Map.fetch!(@labels, &1), value(&1, Map.get(draft, &1))})

  defp rows(_draft), do: []

  defp value(:treasury_path, path), do: Map.fetch!(@paths, path)
  defp value(:chain, chain), do: if(chain == :robinhood, do: "Robinhood Chain", else: "Base")
  defp value(:image, _url), do: "Shown above"
  defp value(_field, value) when value in [nil, ""], do: "Left empty"
  defp value(_field, value), do: value
end
