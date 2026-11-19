defmodule Autolaunch.PointsTesting do
  @moduledoc """
  What the tests of the site's Regent Points sources share: opening earning for
  one test, running the library's queue on the site's Oban, and reading back
  what Points wrote. Autolaunch earns nothing outside production (no start
  time, no rule approved), so each test opens the rules it needs itself.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias RegentPoints.Store

  @unit RegentPoints.Rules.unit()

  @doc """
  Starts the site's Oban, which the site starts only with the database at
  start-up, and opens `rules` from three days ago until the test ends. Answers
  the start.
  """
  def open(rules) do
    start_supervised!({Oban, Application.fetch_env!(:autolaunch, Oban)})

    previous =
      Map.new([:starts_at, :approved_rules], &{&1, Application.fetch_env!(:regent_points, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:regent_points, key, value) end)
    end)

    starts_at = DateTime.add(DateTime.utc_now(), -3 * 86_400)
    Application.put_env(:regent_points, :starts_at, starts_at)
    Application.put_env(:regent_points, :approved_rules, rules)
    starts_at
  end

  @doc "Closes earning again: no start time and no rule approved, as outside production."
  def close do
    Application.put_env(:regent_points, :starts_at, nil)
    Application.put_env(:regent_points, :approved_rules, [])
  end

  @doc """
  A version of the account's verified wallets from an earlier time, as the
  library's capture would have written it then.
  """
  def held_since(account, wallet, at) do
    Autolaunch.Repo.query!(
      """
      INSERT INTO regent_points.wallet_snapshots(account_id, wallet_addresses, effective_at)
      VALUES ($1, $2, $3)
      """,
      [account.id, [wallet], DateTime.to_naive(at)]
    )
  end

  def drain,
    do: assert(%{failure: 0, discard: 0} = Oban.drain_queue(queue: :points, with_recursion: true))

  def events, do: RegentPoints.read_events!(actor: Store.system())
  def events(rule), do: Enum.filter(events(), &(&1.rule_id == rule))

  def entries(rule, points) do
    RegentPoints.read_entries!(actor: Store.system())
    |> Enum.filter(&(&1.rule_id == rule and &1.points_micro_delta == points * @unit))
  end

  @doc "Each award a rule wrote, by the source key it was for, in whole points."
  def earned(rule) do
    keys = Map.new(events(rule), &{&1.id, &1.source_event_key})

    RegentPoints.read_entries!(actor: Store.system())
    |> Enum.filter(&(&1.rule_id == rule))
    |> Enum.map(&{Map.fetch!(keys, &1.event_id), div(&1.points_micro_delta, @unit)})
  end

  @doc """
  What became of each source the rule recorded, as `{source key, status}`,
  sorted: a one-time rule's later offers are recorded too, and those after the
  one that earned end `capped`.
  """
  def outcomes(rule),
    do: rule |> events() |> Enum.map(&{&1.source_event_key, &1.processing_status}) |> Enum.sort()

  @doc "Every refusal Points saved for the source key, as `{rule, reason}`, sorted."
  def rejections(key) do
    RegentPoints.read_rejections!(actor: Store.system())
    |> Enum.filter(&(&1.source["source_event_key"] == key))
    |> Enum.map(&{&1.source["rule_id"], &1.reason_code})
    |> Enum.sort()
  end
end
