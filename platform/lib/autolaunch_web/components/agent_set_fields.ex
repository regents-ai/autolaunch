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
    assigns = assign(assigns, fields: set_fields(assigns.draft), labels: @labels)

    ~H"""
    <section
      :if={@fields != []}
      id="agent-set-fields"
      class="agent-set"
      aria-labelledby="agent-set-title"
    >
      <h3 id="agent-set-title">Your agent filled these in</h3>
      <p>Check each one before you launch. Change any of them above and it is yours.</p>
      <dl>
        <div :for={field <- @fields}>
          <dt>{Map.fetch!(@labels, field)}</dt>
          <dd><.value field={field} value={Map.get(@draft, field)} draft={@draft} /></dd>
        </div>
      </dl>
    </section>
    """
  end

  @doc "The names of agent-set fields, as a launch review's facts list them."
  def labels(fields) when is_list(fields),
    do: fields |> Enum.map(&Map.fetch!(@labels, String.to_existing_atom(&1))) |> Enum.uniq()

  defp set_fields(%{agent_set_fields: fields}) when is_list(fields), do: fields
  defp set_fields(_draft), do: []

  # A whole address on Base is drawn as every Regent page draws one, to open and
  # copy whole. A draft is saved part-way, so anything else shows as written.
  defp value(%{field: :treasury, value: value} = assigns) when is_binary(value) do
    if whole_address?(value), do: address(assigns), else: written(assigns)
  end

  defp value(%{field: :stock_address, value: value, draft: %{chain: :base}} = assigns)
       when is_binary(value) do
    if whole_address?(value), do: address(assigns), else: written(assigns)
  end

  defp value(assigns), do: written(assigns)

  defp whole_address?(value), do: value =~ ~r/\A0x[0-9a-fA-F]{40}\z/

  defp written(assigns), do: ~H"{shown(@field, @value)}"

  defp address(assigns) do
    ~H"""
    <Regent.Primitives.address id={"agent-set-#{@field}"} address={@value} />
    """
  end

  defp shown(:treasury_path, path), do: Map.fetch!(@paths, path)
  defp shown(:chain, chain), do: if(chain == :robinhood, do: "Robinhood Chain", else: "Base")
  defp shown(:image, _url), do: "Shown above"
  defp shown(_field, value) when value in [nil, ""], do: "Left empty"
  defp shown(_field, value), do: value
end
