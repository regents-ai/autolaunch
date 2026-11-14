defmodule AutolaunchWeb.PointsEntries do
  @moduledoc """
  How the Points page and the agent's Points answer describe one account's
  Points (`RegentPoints.summary/1` and the board every reader shares,
  `Autolaunch.Points.Board`), so both say the same thing about each action,
  entry and place.
  """

  alias RegentPoints.{Amount, Rules}

  @doc "What became of an entry: counted, cut to nothing by a daily limit, or a correction."
  def status(%{reversal_of_entry_id: id}) when not is_nil(id), do: :correction
  def status(%{points_micro_delta: 0}), do: :allowance_reached
  def status(_entry), do: :counted

  def status_label(:counted), do: "Counted"
  def status_label(:allowance_reached), do: "Limit reached"
  def status_label(:correction), do: "Correction"

  @doc "Who earned an entry, by the name the person gave their agent."
  def agent_name(%{actor_kind: "agent", actor_id: id}, names),
    do: Map.get(names, id, "Previously connected agent")

  def agent_name(_entry, _names), do: nil

  @doc """
  Every action a Points page lists (`RegentPoints.Rules.groups/0`), under the
  site it belongs to, whichever site earns it, with what the account has done of
  each: `[%{title, items}]`, `title` the site's name. A one-time action is done
  once it was earned on any site; a daily one shows today's times against its
  daily count. An action is left to do only while earning is open (`open?`) and
  this site earns it; before earning opens an action carries no points.
  """
  def todo(summary, open?) do
    room = daily_room(summary)

    for %{site: site, rules: rules} <- Rules.groups() do
      %{
        title: site,
        items: Enum.map(rules, &item(&1, Map.fetch!(summary.done, &1["id"]), room, open?))
      }
    end
  end

  @doc """
  The one limit every daily action shares, whoever acted and on whichever site:
  `%{label, used, of, value}`, or nil while no daily action earns on this site.
  """
  def daily_limit(summary) do
    case daily_room(summary) do
      nil ->
        nil

      %{limit: limit, remaining: remaining} ->
        used = whole(limit - remaining)

        %{
          label: "Daily limit",
          used: used,
          of: whole(limit),
          value: "#{used} of #{whole(limit)} today"
        }
    end
  end

  defp daily_room(summary), do: Enum.find(summary.allowances, &(&1.scope == "activity:account"))

  @doc "How many listed actions can still earn here: today for a daily one."
  def left(groups), do: groups |> Enum.flat_map(& &1.items) |> Enum.count(& &1.left)

  @doc """
  The shared board for one reader: `%{rows, you, rank}`. `reader` is the reader's
  account id and `summary` their own summary, or `nil` while it is not read. `you`
  is the reader's row when they sit below the listed rows, with the place and
  total from their summary; `rank` is their place wherever they sit. The rows'
  account ids stay here: none reaches a page or an agent. A row's `name` is `nil`
  when the person shows by their `wallet`, under its `ens_name` when it has one. A
  row's `line` is its position in the list: names and places repeat, lines do not.
  """
  def board(%{top: top}, reader, summary) do
    own = Enum.find(top, &(&1.account_id == reader))
    you = below(own, summary)

    %{
      rows:
        top
        |> Enum.with_index(1)
        |> Enum.map(fn {row, line} ->
          %{
            line: line,
            rank: row.rank,
            name: row.name,
            wallet: row.wallet,
            ens_name: row.ens_name,
            squares: row.squares,
            picture: row.picture,
            points: Amount.format(row.points_micro),
            you: row.account_id == reader
          }
        end),
      you: you,
      rank: if(own, do: own.rank, else: you && you.rank)
    }
  end

  # The reader's own row under the listed ones, while they have a place.
  defp below(nil, %{place: place, balance_micro: total}) when is_integer(place),
    do: %{rank: place, points: Amount.format(total)}

  defp below(_own, _summary), do: nil

  @doc "The agent's Points answer: the same figures the Points page shows."
  def answer(summary, board, reader, open?) do
    board = board(board, reader, summary)

    %{
      points: Amount.format(summary.balance_micro),
      earned_today: Amount.format(summary.earned_today_micro),
      earned_yesterday: Amount.format(summary.earned_yesterday_micro),
      rank: board.rank,
      activity_being_verified: summary.pending,
      to_do:
        for group <- todo(summary, open?) do
          %{
            site: group.title,
            actions:
              for item <- group.items do
                %{
                  label: item.label,
                  repeats: item.repeats,
                  points: item.points,
                  done: item.done,
                  left: item.left,
                  today: item[:count]
                }
              end
          }
        end,
      daily_limits:
        Enum.map(
          summary.allowances,
          &%{
            name: limit_name(&1.scope),
            limit: Amount.format(&1.limit),
            remaining: Amount.format(&1.remaining)
          }
        ),
      leaderboard:
        Enum.map(board.rows, &Map.take(&1, [:rank, :name, :wallet, :ens_name, :points, :you])),
      entries:
        Enum.map(summary.entries, fn entry ->
          %{
            label: Rules.label(entry.rule_id),
            points: Amount.format(entry.points_micro_delta),
            status: status(entry),
            allowance_reduction: Amount.format(entry.cap_reduction_micro),
            by: if(entry.actor_kind == "agent", do: "agent", else: "person"),
            agent: agent_name(entry, summary.agent_names),
            earned_at: entry.earned_at
          }
        end),
      period_bonuses:
        Enum.map(
          summary.period_bonuses,
          &%{
            period: &1.period,
            points: Amount.format(&1.bonus_micro),
            nft_count: &1.nft_count,
            bonus_percent: &1.bonus_percent
          }
        ),
      more: summary.more?
    }
  end

  defp limit_name("activity:account"), do: "Daily actions, you and your agents"

  # The summary's `done` entry for a rule: how many times the account has had it on
  # any site (ever, or today for a daily one), and whether this site earns it.
  defp item(
         %{"id" => id, "category" => "milestone", "points" => points},
         %{times: times, here: here},
         _room,
         open?
       ) do
    done = times >= 1

    %{
      id: id,
      label: Rules.label(id),
      repeats: "once",
      points: open? && to_string(points),
      done: done,
      left: open? and here and not done
    }
  end

  # A daily action stays to do here until today's count is used, unless the daily
  # limit every daily action shares is spent.
  defp item(
         %{"id" => id, "category" => "activity", "points" => points, "count" => of},
         %{times: times, here: here},
         room,
         open?
       )
       when is_integer(of) do
    %{
      id: id,
      label: Rules.label(id),
      repeats: "daily",
      points: open? && to_string(points),
      note: "#{times} of #{of} today",
      done: times >= of,
      left: open? and here and times < of and match?(%{remaining: r} when r > 0, room)
    }
    |> then(&if of > 1, do: Map.put(&1, :count, %{done: times, of: of}), else: &1)
  end

  defp whole(micro), do: div(micro, Rules.unit())
end
