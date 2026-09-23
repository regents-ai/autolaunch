defmodule AutolaunchWeb.Components.RaiseProgress do
  @moduledoc """
  How far an auction is toward the minimum it must raise to graduate, and
  roughly when bidding opens or ends; once bidding has ended, how the final
  raise compares with the minimum. The amounts and blocks are read from the
  chain; the time is an estimate from the chain's usual block rate, left out on
  a test network, whose blocks are mined on demand.
  """
  use Phoenix.Component

  alias Autolaunch.LaunchChain
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.TokenDisplay

  attr :id, :string, required: true
  attr :state, :atom, required: true
  attr :raised, :string, required: true, doc: "whole units, as a plain decimal"
  attr :required, :string, required: true, doc: "whole units, as a plain decimal"
  attr :symbol, :string, required: true
  attr :block, :integer, required: true, doc: "the block the auction keeps time by"
  attr :start_block, :integer, required: true
  attr :end_block, :integer, required: true
  attr :chain, :atom, required: true, values: LaunchChain.chains()
  attr :test_chain, :boolean, required: true

  # The schedule decides which view shows: an auction can meet its minimum,
  # and so count as graduated, while bidding is still open.
  def raise_progress(%{block: block, start_block: start_block, end_block: end_block} = assigns)
      when block >= start_block and block < end_block do
    percent = percent(assigns.raised, assigns.required)
    assigns = assign(assigns, percent: percent, shown: min(percent, 100))

    ~H"""
    <section id={@id} class="raise-progress" aria-label="Progress to the minimum raise">
      <p class="raise-progress__figure">
        <strong><TokenDisplay.price amount={readable(@raised)} unit={@symbol} /></strong>
        raised of <TokenDisplay.price amount={readable(@required)} unit={@symbol} /> minimum
      </p>
      <progress
        class="raise-progress__bar"
        max="100"
        value={@shown}
        aria-label="Share of the minimum raised"
      >
        {@shown}%
      </progress>
      <p class="raise-progress__note">
        <span>{reached(@raised, @percent)}</span>
        <span :if={@percent < 100}>
          <TokenDisplay.price amount={shortfall(@raised, @required)} unit={@symbol} /> still needed.
        </span>
        <span>{timing("Bidding ends", @end_block - @block, @end_block, @chain, @test_chain)}</span>
      </p>
    </section>
    """
  end

  def raise_progress(%{block: block, end_block: end_block} = assigns) when block >= end_block do
    percent = percent(assigns.raised, assigns.required)
    assigns = assign(assigns, percent: percent, shown: min(percent, 100))

    ~H"""
    <section id={@id} class="raise-progress" aria-label="The final raise">
      <p class="raise-progress__figure">
        <strong><TokenDisplay.price amount={readable(@raised)} unit={@symbol} /></strong>
        raised of <TokenDisplay.price amount={readable(@required)} unit={@symbol} /> minimum
      </p>
      <progress
        class="raise-progress__bar"
        max="100"
        value={@shown}
        aria-label="Share of the minimum raised"
      >
        {@shown}%
      </progress>
      <p class="raise-progress__note">
        <span :if={@percent >= 100}>Minimum reached.</span>
        <span :if={@percent < 100}>
          Short of the minimum by
          <TokenDisplay.price
            amount={shortfall(@raised, @required)}
            unit={@symbol}
          />.
        </span>
        <span>{outcome(@state)}</span>
      </p>
    </section>
    """
  end

  # Bidding has not opened yet.
  def raise_progress(assigns) do
    ~H"""
    <section id={@id} class="raise-progress" aria-label="The minimum raise">
      <p class="raise-progress__figure">
        Must raise <strong><TokenDisplay.price amount={readable(@required)} unit={@symbol} /></strong>
        to graduate
      </p>
      <p class="raise-progress__note">
        <span>
          {timing("Bidding opens", @start_block - @block, @start_block, @chain, @test_chain)}
        </span>
      </p>
    </section>
    """
  end

  # From a thousand up, whole units with separators read best. An amount held
  # drops its fraction and a shortfall rounds it up, so neither is overstated
  # in the auction's favour. Smaller amounts keep their significant digits.
  defp readable(amount, rounding \\ :down) do
    decimal = Decimal.new(amount)

    if Decimal.gte?(decimal, 1000),
      do:
        decimal |> Decimal.round(0, rounding) |> Decimal.to_string(:normal) |> Amounts.grouped(),
      else: Decimal.to_string(decimal, :normal)
  end

  # Rounded down, so the page never shows the minimum as met before it is.
  defp percent(raised, required) do
    raised
    |> Decimal.new()
    |> Decimal.mult(100)
    |> Decimal.div(Decimal.new(required))
    |> Decimal.round(0, :down)
    |> Decimal.to_integer()
  end

  defp shortfall(raised, required),
    do: required |> Decimal.new() |> Decimal.sub(Decimal.new(raised)) |> readable(:ceiling)

  defp outcome(:graduated), do: "The auction graduated."
  defp outcome(:failed), do: "Every bidder can take back their full bid."
  defp outcome(_settling), do: "Bidding has ended."

  defp reached(_raised, percent) when percent >= 100, do: "Minimum reached."

  defp reached(raised, 0) do
    if Decimal.gt?(Decimal.new(raised), 0),
      do: "Under 1% of the minimum.",
      else: "Nothing raised yet."
  end

  defp reached(_raised, percent), do: "#{percent}% of the minimum."

  defp timing(event, _blocks, at, _chain, true),
    do: "#{event} at block #{grouped(at)}."

  defp timing(event, blocks, at, chain, false),
    do: "#{event} in #{LaunchChain.time_estimate(chain, blocks)}, at block #{grouped(at)}."

  defp grouped(block), do: block |> Integer.to_string() |> Amounts.grouped()
end
