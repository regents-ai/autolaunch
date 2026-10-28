defmodule AutolaunchWeb.AgentPairingPropertiesTest do
  @moduledoc """
  The rules of pairing that must hold for every input, through the agent requests
  this site serves (`RegentAgents.HTTP`, `AutolaunchWeb.Plugs.AgentAccess`). The
  sign-in service is stubbed: it verifies each request as the agent whose wallet
  the request names in its signed `x-agent-wallet-address` header, so one case
  can speak as many agents.
  """
  use AutolaunchWeb.ConnCase, async: false
  use ExUnitProperties

  alias Autolaunch.{Repo, TestSupport}
  alias RegentAgents.{Harness, PairingCode, Person}

  @moduletag :capture_log

  setup do
    Req.Test.stub(RegentAgents.Broker, fn broker ->
      {:ok, body, broker} = Plug.Conn.read_body(broker)
      wallet = Jason.decode!(body)["headers"]["x-agent-wallet-address"]

      Req.Test.json(broker, %{
        "code" => "http_envelope_valid",
        "data" => %{
          "verified" => true,
          "principal" => %{
            "kind" => "wallet",
            "wallet_address" => wallet,
            "chain_id" => 8453,
            "audience" => "autolaunch"
          },
          "agentRegistration" => nil,
          "agentBook" => nil
        }
      })
    end)

    :ok
  end

  defp wallet,
    do: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

  # Each request comes from an address of its own, so the per-address request
  # budget never stands between a case and the answer it checks.
  defp as_agent(wallet) do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)

    %{build_conn() | remote_ip: {10, a, b, c}}
    |> put_req_header("x-agent-wallet-address", wallet)
  end

  defp pair(wallet, code, harness \\ "codex") do
    wallet
    |> as_agent()
    |> put_req_header("content-type", "application/json")
    |> post(
      "/api/agents/v1/pair",
      Jason.encode!(%{"code" => code, "name" => "Agent", "harness" => harness})
    )
  end

  defp code_for(privy_user_id) do
    {:ok, issued} = RegentAgents.issue_pairing_code(actor: %Person{privy_user_id: privy_user_id})
    issued.code
  end

  defp person_id, do: "did:privy:property-#{System.unique_integer([:positive])}"

  defp refusal(conn), do: json_response(conn, conn.status)["error"]["code"]

  # PAIRING_CODE_WORKS_ONCE
  property "PAIRING_CODE_WORKS_ONCE: a code pairs exactly one agent, however many try it, in any order and at once" do
    check all(
            agents <- integer(1..4),
            tries <- list_of(integer(0..3), min_length: 1, max_length: 8),
            at_once <- boolean(),
            max_runs: 40
          ) do
      wallets = for _ <- 1..agents, do: wallet()
      attempts = Enum.map(tries, &Enum.at(wallets, rem(&1, agents)))
      person = person_id()
      code = code_for(person)

      try = fn wallet ->
        conn = pair(wallet, code)
        {conn.status, if(conn.status == 201, do: nil, else: refusal(conn))}
      end

      results =
        if at_once,
          do:
            attempts
            |> Task.async_stream(try, max_concurrency: length(attempts))
            |> Enum.map(fn {:ok, result} -> result end),
          else: Enum.map(attempts, try)

      assert Enum.count(results, &(&1 == {201, nil})) == 1
      assert Enum.all?(results, &(&1 in [{201, nil}, {400, "pairing_failed"}]))
      unless at_once, do: assert(hd(results) == {201, nil})

      assert {:ok, [_one]} = RegentAgents.list_my_agents(actor: %Person{privy_user_id: person})
    end
  end

  # PAIRING_CODE_ENDS_AT_TEN_MINUTES
  property "PAIRING_CODE_ENDS_AT_TEN_MINUTES: a code pairs exactly when it is under ten minutes old" do
    # The request is sent within a second of the clock moving, so the second before
    # the edge is left out rather than raced.
    edge = one_of([integer(590..597), integer(600..610)])

    check all(age <- one_of([integer(0..597), integer(600..1_200), edge]), max_runs: 60) do
      code = code_for(person_id())
      hash = PairingCode.hash(code)

      Repo.query!(
        """
        UPDATE regent_agents.pairing_codes
        SET issued_at = issued_at - make_interval(secs => $2),
            expires_at = expires_at - make_interval(secs => $2)
        WHERE code_hash = $1
        """,
        [hash, age]
      )

      conn = pair(wallet(), code)

      if age < 600,
        do: assert(conn.status == 201),
        else: assert({conn.status, refusal(conn)} == {400, "pairing_failed"})
    end
  end

  # ONLY_OFFERED_HARNESSES_PAIR
  property "ONLY_OFFERED_HARNESSES_PAIR: an agent pairs exactly when its harness is one this site offers, and never as ChatGPT" do
    known = Enum.map(Harness.values(), &Atom.to_string/1)
    offered = Enum.map(Harness.offered(), &Atom.to_string/1)

    junk =
      string(:alphanumeric, min_length: 1, max_length: 16)
      |> filter(&(String.downcase(&1) not in known))

    check all(harness <- one_of([member_of(known), junk]), max_runs: 80) do
      conn = pair(wallet(), code_for(person_id()), harness)

      if harness in offered,
        do: assert(conn.status == 201),
        else: assert({conn.status, refusal(conn)} == {400, "harness_unknown"})
    end

    refute "chatgpt" in offered
  end

  # PAIR_TAKES_EXACTLY_CODE_NAME_AND_HARNESS
  property "PAIR_TAKES_EXACTLY_CODE_NAME_AND_HARNESS: a pair request with any other set of fields spends nothing and is refused" do
    check all(
            keep <- list_of(member_of(~w(code name harness)), max_length: 3),
            extra <-
              map_of(string(:alphanumeric, min_length: 1, max_length: 8), string(:alphanumeric),
                max_length: 2
              ),
            keep = Enum.uniq(keep),
            extra = Map.drop(extra, ~w(code name harness)),
            length(keep) < 3 or extra != %{},
            max_runs: 60
          ) do
      person = person_id()
      code = code_for(person)
      full = %{"code" => code, "name" => "Agent", "harness" => "codex"}
      agent = wallet()

      conn =
        agent
        |> as_agent()
        |> put_req_header("content-type", "application/json")
        |> post("/api/agents/v1/pair", Jason.encode!(Map.merge(Map.take(full, keep), extra)))

      assert {conn.status, refusal(conn)} == {400, "pairing_failed"}
      assert pair(agent, code).status == 201
    end
  end

  # AGENT_LIMIT_IS_ONE_HUNDRED
  test "AGENT_LIMIT_IS_ONE_HUNDRED: an account holds a hundred agents, and the next pairing is refused" do
    person = person_id()
    for _ <- 1..100, do: assert(pair(wallet(), code_for(person)).status == 201)
    conn = pair(wallet(), code_for(person))
    assert {conn.status, refusal(conn)} == {409, "agent_limit"}
  end

  # AN_AGENT_ACTS_ONLY_FOR_ITS_OWN_PERSON
  property "AN_AGENT_ACTS_ONLY_FOR_ITS_OWN_PERSON: every private answer names the account of the agent's current pairing, or refuses" do
    check all(
            steps <-
              list_of(
                tuple({member_of([:pair, :unpair, :read, :read]), integer(0..3), integer(0..2)}),
                min_length: 1,
                max_length: 14
              ),
            max_runs: 30
          ) do
      people = for _ <- 0..2, do: TestSupport.register_creator!()
      agents = for _ <- 0..3, do: wallet()

      Enum.reduce(steps, %{}, fn {step, agent_index, person_index}, paired ->
        agent = Enum.at(agents, agent_index)
        person = Enum.at(people, person_index)
        act(step, agent, person, paired)
      end)
    end
  end

  # A paired agent may also redeem another person's code; whichever person the
  # site then pairs it with, every later answer must name that person alone.
  defp act(:pair, agent, person, paired) do
    case pair(agent, code_for(person.privy_user_id)) do
      %{status: 201} ->
        Map.put(paired, agent, person)

      %{status: status} when is_map_key(paired, agent) and status in 400..499 ->
        paired
    end
  end

  # Unpairing one that is not paired is a read.

  defp act(:unpair, agent, _person, paired) when is_map_key(paired, agent) do
    owner = %Person{privy_user_id: paired[agent].privy_user_id}
    {:ok, mine} = RegentAgents.list_my_agents(actor: owner)
    :ok = mine |> Enum.find(&(&1.wallet == agent)) |> RegentAgents.unpair_agent(actor: owner)
    Map.delete(paired, agent)
  end

  defp act(_read, agent, _person, paired) do
    conn = agent |> as_agent() |> get("/api/agents/v1/me")

    case paired do
      %{^agent => person} ->
        assert json_response(conn, 200)["data"]["account"]["wallet_address"] ==
                 person.wallet_address

      _unpaired ->
        assert {conn.status, refusal(conn)} == {403, "agent_not_paired"}
    end

    paired
  end
end
