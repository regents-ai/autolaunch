defmodule Autolaunch.Accounts.XOAuthTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{SessionAuthority, XOAuth}
  alias Autolaunch.Actors.System

  defmodule Strategy do
    def authorize_url(config),
      do: Application.fetch_env!(:autolaunch, :x_oauth_test_authorize).(config)

    def callback(config, params),
      do: Application.fetch_env!(:autolaunch, :x_oauth_test_callback).(config, params)
  end

  setup do
    test_pid = self()
    now = ~U[2026-08-30 19:00:00.000000Z]
    {:ok, clock} = Agent.start_link(fn -> now end)
    {:ok, attempt_counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:autolaunch, :x_oauth_client_id, "public-x-client")
    Application.put_env(:autolaunch, :x_oauth_strategy, Strategy)
    Application.put_env(:autolaunch, :x_oauth_clock, fn -> Agent.get(clock, & &1) end)

    Application.put_env(:autolaunch, :x_oauth_test_authorize, fn config ->
      count = Agent.get_and_update(attempt_counter, &{&1 + 1, &1 + 1})
      state = "state-#{count}-#{Ash.UUID.generate()}"
      verifier = "verifier-#{count}-#{Ash.UUID.generate()}"
      send(test_pid, {:authorize, config, state, verifier})

      {:ok,
       %{
         url: "https://x.example.test/authorize?state=#{URI.encode_www_form(state)}",
         session_params: %{state: state, code_verifier: verifier}
       }}
    end)

    Application.put_env(:autolaunch, :x_oauth_test_callback, fn config, params ->
      send(test_pid, {:callback, config, params})

      {:ok,
       %{
         token: %{"access_token" => "discard-me"},
         user: %{
           "data" => %{
             "id" => "x-user-1",
             "username" => "verified_creator",
             "name" => "Verified Creator",
             "profile_image_url" => "https://images.example.test/creator.png"
           }
         }
       }}
    end)

    on_exit(fn ->
      for key <- [
            :x_oauth_client_id,
            :x_oauth_strategy,
            :x_oauth_clock,
            :x_oauth_test_authorize,
            :x_oauth_test_callback,
            :x_oauth_expired_cleanup_observer
          ],
          do: Application.delete_env(:autolaunch, key)
    end)

    {:ok, clock: clock}
  end

  test "PKCE completion stores only verified public identity and rejects replay" do
    account = account!("complete")
    claim = claim!(account)

    assert {:ok, %{role: :profile, generation: generation}} =
             XOAuth.begin(claim, :profile, intent())

    assert_receive {:authorize, config, state, verifier}
    assert config[:client_id] == "public-x-client"
    assert config[:authorization_params][:scope] == "tweet.read users.read"
    refute config[:authorization_params][:scope] =~ "offline.access"
    refute Keyword.has_key?(config, :client_secret)

    assert {:ok, %{role: :profile, generation: ^generation}} =
             XOAuth.callback(claim, %{"state" => state, "code" => "one-use-code"})

    assert_receive {:callback, callback_config, %{"code" => "one-use-code"}}
    assert callback_config[:session_params] == %{state: state, code_verifier: verifier}

    assert {:ok, connection} = Accounts.get_my_x_connection(:profile, actor: human(account))
    assert connection.x_user_id == "x-user-1"
    assert connection.username == "verified_creator"
    assert connection.attempt_state == nil
    assert connection.attempt_verifier == nil
    assert connection.attempt_expires_at == nil
    assert connection.attempt_generation != generation

    inspected = inspect(connection)
    refute inspected =~ "discard-me"
    refute inspected =~ "one-use-code"

    assert {:error, _reason} =
             XOAuth.callback(claim, %{"state" => state, "code" => "replay"})

    refute_receive {:callback, _config, %{"code" => "replay"}}
  end

  test "wrong account, wrong state, expiry, and session refresh fail before provider access", %{
    clock: clock
  } do
    owner = account!("owner")
    other = account!("other")
    claim = claim!(owner)
    other_claim = claim!(other)

    assert {:ok, _started} = XOAuth.begin(claim, :company, intent())
    assert_receive {:authorize, _config, state, _verifier}

    assert {:error, _reason} =
             XOAuth.callback(other_claim, %{"state" => state, "code" => "wrong-account"})

    assert {:error, _reason} =
             XOAuth.callback(claim, %{"state" => "wrong-state", "code" => "wrong-state"})

    refute_receive {:callback, _config, _params}

    Agent.update(clock, &DateTime.add(&1, 601, :second))
    assert {:error, _reason} = XOAuth.callback(claim, %{"state" => state, "code" => "late"})
    refute_receive {:callback, _config, _params}

    assert {:ok, expired} = Accounts.get_my_x_connection(:company, actor: human(owner))
    assert expired.attempt_state == nil
    assert expired.attempt_verifier == nil
    assert expired.attempt_generation == nil

    Agent.update(clock, fn _ -> ~U[2026-08-30 19:00:00.000000Z] end)
    assert {:ok, _started} = XOAuth.begin(claim, :company, intent())
    assert_receive {:authorize, _config, refreshed_state, _verifier}
    assert {:ok, :refresh, new_claim} = SessionAuthority.sign_in(claim, owner.id)

    assert {:error, :stale_authority} =
             XOAuth.callback(claim, %{"state" => refreshed_state, "code" => "stale-session"})

    assert {:error, :invalid_or_expired_attempt} =
             XOAuth.callback(new_claim, %{
               "state" => refreshed_state,
               "code" => "refreshed-session"
             })

    refute_receive {:callback, _config, _params}

    assert {:ok, invalidated} = Accounts.get_my_x_connection(:company, actor: human(owner))
    assert invalidated.attempt_state == nil
    assert invalidated.attempt_verifier == nil
    assert invalidated.attempt_generation == nil
  end

  test "wrong role and a replaced PKCE verifier fail without creating an identity" do
    account = account!("wrong-role-verifier")
    claim = claim!(account)

    assert {:error, :invalid_role} = XOAuth.begin(claim, :operator, intent())
    refute_receive {:authorize, _config, _state, _verifier}

    assert {:ok, _started} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, state, verifier}
    actor = human(account)
    assert {:ok, connection} = Accounts.get_my_x_connection(:profile, actor: actor)

    assert {:ok, _tampered} =
             Accounts.replace_x_connection_attempt(
               connection,
               %{
                 attempt_state: connection.attempt_state,
                 attempt_verifier: "not-the-original-verifier",
                 attempt_generation: connection.attempt_generation,
                 attempt_expires_at: connection.attempt_expires_at
               },
               actor: actor
             )

    Application.put_env(:autolaunch, :x_oauth_test_callback, fn config, _params ->
      if config[:session_params][:code_verifier] == verifier,
        do: {:ok, %{user: %{}}},
        else: {:error, :wrong_verifier}
    end)

    assert {:error, :wrong_verifier, %{role: :profile, generation: generation}} =
             XOAuth.callback(claim, %{"state" => state, "code" => "wrong-verifier"})

    assert generation == connection.attempt_generation

    assert {:ok, refused} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert refused.x_user_id == nil
    assert refused.verified_at == nil
    assert refused.attempt_state == nil
    assert refused.attempt_verifier == nil
  end

  test "Profile and Company attempts remain independent even for the same X user" do
    account = account!("role-overlap")
    claim = claim!(account)

    connect!(claim, :profile)
    connect!(claim, :company)

    assert {:ok, connections} = Accounts.list_my_x_connections(actor: human(account))
    assert Enum.map(connections, & &1.role) == [:company, :profile]
    assert Enum.uniq(Enum.map(connections, & &1.x_user_id)) == ["x-user-1"]
  end

  test "failed reconnect preserves identity while explicit disconnect clears it" do
    account = account!("reconnect")
    claim = claim!(account)
    connect!(claim, :profile)

    assert {:ok, before} = Accounts.get_my_x_connection(:profile, actor: human(account))
    assert before.username == "verified_creator"

    assert {:ok, %{generation: generation}} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, state, _verifier}

    Application.put_env(:autolaunch, :x_oauth_test_callback, fn _config, _params ->
      {:error, :provider_refused}
    end)

    assert {:error, :provider_refused, %{role: :profile, generation: ^generation}} =
             XOAuth.callback(claim, %{"state" => state, "error" => "access_denied"})

    assert {:ok, retained} = Accounts.get_my_x_connection(:profile, actor: human(account))
    assert retained.x_user_id == before.x_user_id
    assert retained.username == before.username
    assert retained.verified_at == before.verified_at
    assert retained.attempt_state == nil
    assert retained.attempt_verifier == nil

    assert {:ok, %{role: :profile}} = XOAuth.disconnect(claim, :profile, intent())
    assert {:ok, disconnected} = Accounts.get_my_x_connection(:profile, actor: human(account))
    assert disconnected.username == nil
    assert disconnected.verified_at == nil
  end

  test "concurrent replay permits one conditional completion" do
    account = account!("concurrent")
    claim = claim!(account)

    assert {:ok, _started} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, state, _verifier}

    results =
      1..2
      |> Task.async_stream(
        fn sequence ->
          XOAuth.callback(claim, %{"state" => state, "code" => "code-#{sequence}"})
        end,
        ordered: false,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _payload}, &1)) == 1
    assert Enum.count(results, &match?({:error, _reason, _payload}, &1)) == 1
  end

  test "logout while the provider callback is in flight makes the completion inert" do
    account = account!("logout-in-flight")
    claim = claim!(account)
    test_pid = self()

    assert {:ok, _started} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, state, _verifier}

    Application.put_env(:autolaunch, :x_oauth_test_callback, fn _config, _params ->
      send(test_pid, {:provider_waiting, self()})

      receive do
        :release_provider ->
          {:ok,
           %{
             user: %{
               "data" => %{
                 "id" => "late-user",
                 "username" => "late_user",
                 "name" => "Late User"
               }
             }
           }}
      end
    end)

    callback =
      Task.async(fn ->
        XOAuth.callback(claim, %{"state" => state, "code" => "late-code"})
      end)

    assert_receive {:provider_waiting, provider_pid}
    assert is_binary(SessionAuthority.revoke(claim))
    send(provider_pid, :release_provider)
    assert {:error, _reason, %{role: :profile, generation: _generation}} = Task.await(callback)

    assert {:ok, public} = Accounts.list_public_x_connections([account.id])
    assert public == []
  end

  test "disconnect and a newer reconnect supersede an in-flight reconnect" do
    account = account!("disconnect-reconnect-order")
    claim = claim!(account)
    test_pid = self()
    connect!(claim, :profile)
    successful_callback = Application.fetch_env!(:autolaunch, :x_oauth_test_callback)

    assert {:ok, _old_attempt} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, old_state, _verifier}

    Application.put_env(:autolaunch, :x_oauth_test_callback, fn _config, _params ->
      send(test_pid, {:reconnect_waiting, self()})

      receive do
        :release_reconnect -> successful_callback.([], %{})
      end
    end)

    old_callback =
      Task.async(fn ->
        XOAuth.callback(claim, %{"state" => old_state, "code" => "old-code"})
      end)

    assert_receive {:reconnect_waiting, provider_pid}
    assert {:ok, %{role: :profile}} = XOAuth.disconnect(claim, :profile, intent())
    assert {:ok, _new_attempt} = XOAuth.begin(claim, :profile, intent())
    assert_receive {:authorize, _config, new_state, _verifier}

    send(provider_pid, :release_reconnect)

    assert {:error, :stale_attempt, %{role: :profile, generation: _generation}} =
             Task.await(old_callback)

    Application.put_env(:autolaunch, :x_oauth_test_callback, successful_callback)

    assert {:ok, %{role: :profile}} =
             XOAuth.callback(claim, %{"state" => new_state, "code" => "new-code"})

    assert_receive {:callback, _config, %{"code" => "new-code"}}
    assert {:ok, current} = Accounts.get_my_x_connection(:profile, actor: human(account))
    assert current.username == "verified_creator"
  end

  test "a newer disconnect wins when an older Change request reaches the row later" do
    account = account!("reversed-intent-arrival")
    claim = claim!(account)
    connect!(claim, :profile)
    actor = human(account)
    assert {:ok, connected} = Accounts.get_my_x_connection(:profile, actor: actor)
    older = intent_after(connected.intent_sequence, 1)
    newer = intent_after(connected.intent_sequence, 2)
    test_pid = self()

    Application.put_env(:autolaunch, :x_oauth_test_authorize, fn config ->
      send(test_pid, {:older_change_waiting, self()})

      result =
        receive do
          :release_older_change ->
            {:ok,
             %{
               url: "https://x.example.test/authorize?state=late-state",
               session_params: %{state: "late-state", code_verifier: "late-verifier"}
             }}
        end

      send(test_pid, {:older_authorized, config})
      result
    end)

    older_change = Task.async(fn -> XOAuth.begin(claim, :profile, older) end)
    assert_receive {:older_change_waiting, provider_pid}
    assert {:ok, %{role: :profile}} = XOAuth.disconnect(claim, :profile, newer)
    send(provider_pid, :release_older_change)
    assert {:error, :stale_intent} = Task.await(older_change)

    assert {:ok, current} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert current.intent_sequence == newer.intent_sequence
    assert current.intent_generation == newer.intent_generation
    assert current.verified_at == nil
    assert current.attempt_state == nil
  end

  test "popup cancellation is exact, expires safely, and cannot clear a newer attempt", %{
    clock: clock
  } do
    account = account!("exact-popup-cancel")
    claim = claim!(account)
    actor = human(account)
    first = intent()

    assert {:ok, _started} = XOAuth.begin(claim, :profile, first)
    assert_receive {:authorize, _config, _state, _verifier}

    cancellation =
      first
      |> intent_after(1)
      |> Map.merge(%{
        cancel_sequence: first.intent_sequence,
        cancel_generation: first.intent_generation
      })

    assert {:ok, _cancelled} = XOAuth.cancel(claim, :profile, cancellation)
    assert {:ok, cleared} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert cleared.attempt_state == nil

    newer = intent_after(cancellation.intent_sequence, 1)
    assert {:ok, _started} = XOAuth.begin(claim, :profile, newer)
    assert_receive {:authorize, _config, _state, _verifier}

    wrong_generation =
      newer
      |> intent_after(1)
      |> Map.merge(%{
        cancel_sequence: newer.intent_sequence,
        cancel_generation: Ash.UUID.generate()
      })

    assert {:error, :stale_intent} = XOAuth.cancel(claim, :profile, wrong_generation)

    assert {:error, :stale_intent} = XOAuth.cancel(claim, :profile, cancellation)
    assert {:ok, retained} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert retained.intent_generation == newer.intent_generation
    assert is_binary(retained.attempt_state)

    Agent.update(clock, &DateTime.add(&1, 601, :second))
    assert {:ok, [_connection]} = XOAuth.list_for_account(account)
    assert {:ok, expired} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert expired.intent_generation == newer.intent_generation
    assert expired.attempt_state == nil
    assert expired.attempt_verifier == nil
  end

  test "expired cleanup cannot clear an attempt that replaced its stale snapshot", %{clock: clock} do
    account = account!("expired-cleanup-race")
    claim = claim!(account)
    actor = human(account)
    old_intent = intent()
    test_pid = self()

    assert {:ok, _started} = XOAuth.begin(claim, :profile, old_intent)
    assert_receive {:authorize, _config, _state, _verifier}
    Agent.update(clock, &DateTime.add(&1, 601, :second))

    Application.put_env(:autolaunch, :x_oauth_expired_cleanup_observer, fn snapshot ->
      send(test_pid, {:expired_snapshot_observed, self(), snapshot})

      receive do
        :continue_expired_cleanup -> :ok
      end
    end)

    cleanup = Task.async(fn -> XOAuth.list_for_account(account) end)

    assert_receive {:expired_snapshot_observed, cleanup_pid,
                    %{role: :profile, generation: old_generation}}

    newer_intent = intent_after(old_intent, 1)
    assert {:ok, %{generation: new_generation}} = XOAuth.begin(claim, :profile, newer_intent)
    assert_receive {:authorize, _config, new_state, _verifier}
    refute new_generation == old_generation

    send(cleanup_pid, :continue_expired_cleanup)
    assert {:ok, [listed]} = Task.await(cleanup)
    assert listed.attempt_state == new_state
    assert listed.attempt_generation == new_generation

    assert {:ok, current} = Accounts.get_my_x_connection(:profile, actor: actor)
    assert current.attempt_state == new_state
    assert current.attempt_generation == new_generation
    assert current.intent_generation == newer_intent.intent_generation
  end

  defp connect!(claim, role) do
    assert {:ok, _started} = XOAuth.begin(claim, role, intent())
    assert_receive {:authorize, _config, state, _verifier}
    assert {:ok, _completed} = XOAuth.callback(claim, %{"state" => state, "code" => "code"})
    assert_receive {:callback, _config, _params}
  end

  defp claim!(account) do
    assert {:ok, :bind, claim} =
             SessionAuthority.sign_in(SessionAuthority.bootstrap(), account.id)

    claim
  end

  defp account!(suffix) do
    nonce = Elixir.System.unique_integer([:positive])

    wallet =
      "0x" <>
        (:crypto.hash(:sha256, "#{suffix}:#{nonce}")
         |> Base.encode16(case: :lower)
         |> binary_part(0, 40))

    Accounts.register_verified!(
      "did:privy:x-oauth:#{suffix}:#{nonce}",
      wallet,
      [wallet],
      actor: %System{}
    )
  end

  defp human(account),
    do: %Autolaunch.Actors.Human{human_account_id: account.id}

  defp intent do
    %{
      intent_sequence: Elixir.System.unique_integer([:positive, :monotonic]),
      intent_generation: Ash.UUID.generate()
    }
  end

  defp intent_after(%{intent_sequence: sequence}, increment),
    do: intent_after(sequence, increment)

  defp intent_after(sequence, increment) when is_integer(sequence) do
    %{
      intent_sequence: sequence + increment,
      intent_generation: Ash.UUID.generate()
    }
  end
end
