defmodule AutolaunchWeb.AgentGuideSentencesTest do
  @moduledoc """
  The guides' sentences on who does what, in each of the 32 ways the five
  agent switches with a wallet step can stand: every served guide is whole,
  names what each switched-on feature lets a paired agent prepare, points to
  each one's section where it points to sections, never names a switched-off
  one as an agent's, and never says that what a switched-on feature prepares
  stays with the person, is not exposed or is not registered as an agent tool.
  """
  use AutolaunchWeb.ConnCase, async: false

  @guides ~w(/ /docs /llms.txt /llms-full.txt /agents.md /skill.md)
  # The guides with a section for each switched-on agent feature.
  @sectioned ~w(/docs /llms-full.txt /agents.md /skill.md)
  # Each agent feature with a wallet step, by its switch: its guide section,
  # and how a guide names what it prepares.
  @features [
    {:agent_bids, "Agent bids", ~r/\bbid on a [\w ]*\bBase\b[\w ]* auction\b/},
    {:agent_robinhood_bids, "Robinhood bids",
     ~r/\bbid on a [\w ]*\bRobinhood Chain\b[\w ]* auction\b/},
    {:agent_launches, "Agent launches",
     ~r/\blaunch step\b|\blaunch of (?:the|your) person's saved draft\b/},
    {:agent_finish, "Finishing auctions", ~r/\bfinish(?: step)? of an ended auction\b/},
    {:agent_staking, "Agent staking", ~r/\bstake, unstake or claim\b/}
  ]
  @switches for {key, _section, _prepares} <- @features, do: key
  # How a guide would name each feature's operations among what stays with
  # the person.
  @kept %{
    agent_bids:
      ~r/\bbidding\b|\bsettlement\b|\bbid controls\b|\bfinancial\b|\b(?:the|your) person's bids\b|\bBase\b/i,
    agent_robinhood_bids:
      ~r/\bbidding\b|\bsettlement\b|\bbid controls\b|\bfinancial\b|\b(?:the|your) person's bids\b|\bRobinhood\b/i,
    agent_launches: ~r/\blaunch(?:es|ing)?\b/i,
    agent_finish: ~r/\bfinish/i,
    agent_staking: ~r/\bstak(?:e|es|ing)\b|\bclaim(?:s|ing)?\b|\bfinancial\b/i
  }
  # The ways a guide says what stays with the person, each in its own clause,
  # and the way it denies agents every operation its sentence names.
  @person_only [
    ~r/\bremain person-controlled\b/i,
    ~r/\bnot registered as agent tools\b/i,
    ~r/\bdoes not expose\b/i,
    ~r/\bstays? on the (?:site's pages|auction's page)\b/i,
    ~r/\bthrough the person-controlled interface\b/i,
    ~r/\bhappen on the website\b/i
  ]
  @denies_agents ~r/\bno agent tool or command\b/i

  setup do
    for key <- @switches do
      previous = Application.fetch_env(:autolaunch, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:autolaunch, key, value)
          :error -> Application.delete_env(:autolaunch, key)
        end
      end)
    end

    :ok
  end

  test "AGENT_GUIDE_SENTENCES_NAMED: in every way the agent switches stand, each guide is whole and names, as a paired agent's to prepare, exactly the switched-on features, pointing to each one's section where it points to sections" do
    for on <- subsets(), {path, guide} <- guides(on) do
      named = "#{inspect(on)} #{path}"
      refute guide =~ "{{", named
      refute guide =~ "%{", named

      told = without_sections(guide)
      prepared = told |> sentences() |> Enum.filter(&(&1 =~ ~r/\bprepares?\b/))

      for {key, _section, prepares} <- @features do
        assert Enum.any?(prepared, &(&1 =~ prepares)) == key in on, "#{named}: #{key}"
      end

      pointed =
        for [_see, sections] <- Regex.scan(~r/\(see ([^)]*)\)/, told),
            {key, section, _prepares} <- @features,
            sections =~ section,
            uniq: true,
            do: key

      assert pointed -- on == [], named
      if path in @sectioned, do: assert(on -- pointed == [], named)
    end
  end

  test "AGENT_GUIDE_SENTENCES_NOT_KEPT: in every way the agent switches stand, no guide says that what a switched-on feature prepares stays with the person, is not exposed or is not registered as an agent tool" do
    for on <- subsets(), {path, guide} <- guides(on), key <- on do
      kept = Enum.filter(person_only(guide), &(&1 =~ @kept[key]))
      assert kept == [], "#{inspect(on)} #{path}: #{key} kept in #{inspect(kept)}"
    end
  end

  # Every set of the switches, from none to all.
  defp subsets do
    Enum.reduce(Enum.reverse(@switches), [[]], fn key, subsets ->
      subsets ++ Enum.map(subsets, &[key | &1])
    end)
  end

  # Each guide as served with the switches in `on` on and the others off.
  defp guides(on) do
    for key <- @switches,
        do: Application.put_env(:autolaunch, key, if(key in on, do: :on, else: :off))

    for path <- @guides do
      {path,
       build_conn() |> put_req_header("accept", "text/markdown") |> get(path) |> response(200)}
    end
  end

  # A guide without the features' own sections, so what is left is what the
  # rest of it says about them.
  defp without_sections(guide) do
    sections = Enum.map_join(@features, "|", fn {_key, section, _prepares} -> section end)
    Regex.replace(~r/^## (?:#{sections})\n.*?(?=^## |\z)/ms, guide, "")
  end

  # Each sentence of a guide, its line breaks as spaces.
  defp sentences(text), do: text |> String.replace(~r/\s+/, " ") |> String.split(~r/(?<=\.) /)

  # Each clause that says what stays with the person, and each sentence that
  # denies agents all it names.
  defp person_only(guide) do
    for sentence <- sentences(guide),
        clause <-
          if(sentence =~ @denies_agents, do: [sentence], else: String.split(sentence, ";")),
        Enum.any?([@denies_agents | @person_only], &(clause =~ &1)),
        do: clause
  end
end
