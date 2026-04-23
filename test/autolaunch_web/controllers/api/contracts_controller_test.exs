defmodule AutolaunchWeb.Api.ContractsControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts

  @wallet "0x1111111111111111111111111111111111111111"

  defmodule ContractsStub do
    @authorized_wallet "0x1111111111111111111111111111111111111111"

    def admin_overview do
      {:ok,
       %{
         admin_contracts: %{
           revenue_share_factory: %{address: "0x1111111111111111111111111111111111111111"}
         }
       }}
    end

    def job_state("job_contracts", human) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             job: %{
               job_id: "job_contracts",
               token_address: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
             },
             strategy: %{address: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def job_state(_job_id, human) do
      case access_status(human) do
        :authorized -> {:error, :not_found}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def subject_state(subject_id, human) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             subject: %{
               subject_id: String.downcase(subject_id),
               splitter_address: "0x9999999999999999999999999999999999999999"
             },
             registry: %{address: "0x2222222222222222222222222222222222222222"}
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_job_action("job_contracts", "strategy", "migrate", _attrs, human) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             job_id: "job_contracts",
             prepared: %{
               resource: "strategy",
               action: "migrate",
               tx_request: %{
                 chain_id: 84_532,
                 to: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                 value: "0x0",
                 data: "0x8fd3ab80"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_job_action(
          "job_contracts",
          "vesting",
          "propose_beneficiary_rotation",
          %{"beneficiary" => beneficiary},
          human
        ) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             job_id: "job_contracts",
             prepared: %{
               resource: "vesting",
               action: "propose_beneficiary_rotation",
               params: %{"beneficiary" => beneficiary},
               tx_request: %{
                 chain_id: 84_532,
                 to: "0xdddddddddddddddddddddddddddddddddddddddd",
                 value: "0x0",
                 data: "0xc178cb2d"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_job_action("job_invalid_address", _resource, _action, _attrs, human) do
      case access_status(human) do
        :authorized -> {:error, :invalid_address}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def prepare_job_action(_job_id, _resource, _action, _attrs, human) do
      case access_status(human) do
        :authorized -> {:error, :unsupported_action}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def prepare_subject_action("subject_forbidden", _resource, _action, _attrs, _human),
      do: {:error, :forbidden}

    def prepare_subject_action(
          subject_id,
          "splitter",
          "set_paused",
          %{"paused" => "true"},
          human
        ) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             subject_id: String.downcase(subject_id),
             prepared: %{
               resource: "splitter",
               action: "set_paused",
               tx_request: %{
                 chain_id: 84_532,
                 to: "0x9999999999999999999999999999999999999999",
                 value: "0x0",
                 data: "0x16c38b3c"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_subject_action(
          subject_id,
          "splitter",
          "sweep_treasury_residual",
          %{"amount" => "7"},
          human
        ) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             subject_id: String.downcase(subject_id),
             prepared: %{
               resource: "splitter",
               action: "sweep_treasury_residual",
               tx_request: %{
                 chain_id: 84_532,
                 to: "0x9999999999999999999999999999999999999999",
                 value: "0x0",
                 data: "0xe37459b1"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_subject_action(
          subject_id,
          "registry",
          "rotate_safe",
          %{"new_safe" => new_safe},
          human
        ) do
      case access_status(human) do
        :authorized ->
          {:ok,
           %{
             subject_id: String.downcase(subject_id),
             prepared: %{
               resource: "registry",
               action: "rotate_safe",
               params: %{"new_safe" => new_safe},
               tx_request: %{
                 chain_id: 84_532,
                 to: "0x2222222222222222222222222222222222222222",
                 value: "0x0",
                 data: "0xdbf6fd39"
               }
             }
           }}

        :unauthorized ->
          {:error, :unauthorized}

        :forbidden ->
          {:error, :forbidden}
      end
    end

    def prepare_subject_action(_subject_id, _resource, _action, _attrs, human) do
      case access_status(human) do
        :authorized -> {:error, :unsupported_action}
        :unauthorized -> {:error, :unauthorized}
        :forbidden -> {:error, :forbidden}
      end
    end

    def prepare_admin_action("revenue_share_factory", "set_authorized_creator", _attrs) do
      {:ok,
       %{
         prepared: %{
           resource: "revenue_share_factory",
           action: "set_authorized_creator",
           tx_request: %{
             chain_id: 84_532,
             to: "0x1111111111111111111111111111111111111111",
             value: "0x0",
             data: "0xe1434f4e"
           }
         }
       }}
    end

    def prepare_admin_action("broken", "set_authorized_creator", _attrs),
      do: {:error, :invalid_uint}

    def prepare_admin_action(_resource, _action, _attrs), do: {:error, :unsupported_action}

    defp access_status(nil), do: :unauthorized

    defp access_status(%{} = human) do
      [Map.get(human, :wallet_address) | List.wrap(Map.get(human, :wallet_addresses))]
      |> Enum.map(&normalize_address/1)
      |> Enum.any?(&(&1 == @authorized_wallet))
      |> then(fn
        true -> :authorized
        false -> :forbidden
      end)
    end

    defp access_status(_human), do: :unauthorized

    defp normalize_address(value) when is_binary(value) do
      value |> String.trim() |> String.downcase()
    end

    defp normalize_address(_value), do: nil
  end

  setup %{conn: conn} do
    original = Application.get_env(:autolaunch, :contracts_api, [])
    Application.put_env(:autolaunch, :contracts_api, context_module: ContractsStub)
    on_exit(fn -> Application.put_env(:autolaunch, :contracts_api, original) end)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("did:privy:contracts-controller", %{
        "wallet_address" => @wallet,
        "wallet_addresses" => [@wallet],
        "display_name" => "Contracts Operator"
      })

    {:ok, wrong_human} =
      Accounts.upsert_human_by_privy_id("did:privy:contracts-controller-wrong", %{
        "wallet_address" => "0x2222222222222222222222222222222222222222",
        "wallet_addresses" => ["0x2222222222222222222222222222222222222222"],
        "display_name" => "Wrong Wallet"
      })

    %{conn: conn, human: human, wrong_human: wrong_human}
  end

  defp signed_in_conn(conn, human) do
    init_test_session(conn, privy_user_id: human.privy_user_id)
  end

  defp contracts_admin_path, do: "/v1/app/contracts/admin"
  defp contracts_job_path(job_id), do: "/v1/app/contracts/jobs/#{job_id}"

  defp contracts_job_prepare_path(job_id, resource, action) do
    "/v1/app/contracts/jobs/#{job_id}/#{resource}/#{action}/prepare"
  end

  defp contracts_subject_path(subject_id), do: "/v1/app/contracts/subjects/#{subject_id}"

  defp contracts_subject_prepare_path(subject_id, resource, action) do
    "/v1/app/contracts/subjects/#{subject_id}/#{resource}/#{action}/prepare"
  end

  defp contracts_admin_prepare_path(resource, action) do
    "/v1/app/contracts/admin/#{resource}/#{action}/prepare"
  end

  test "contract routes reject unauthenticated access across admin, job, subject, and prepare flows",
       %{conn: conn} do
    subject_id = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(get(conn, contracts_admin_path()), 401)

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(get(conn, contracts_job_path("job_contracts")), 401)

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(get(conn, contracts_subject_path(subject_id)), 401)

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(
               post(
                 conn,
                 contracts_job_prepare_path("job_contracts", "strategy", "migrate"),
                 %{}
               ),
               401
             )

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(
               post(
                 conn,
                 contracts_admin_prepare_path("revenue_share_factory", "set_authorized_creator"),
                 %{}
               ),
               401
             )

    assert %{"ok" => false, "error" => %{"code" => "auth_required"}} =
             json_response(
               post(
                 conn,
                 contracts_subject_prepare_path(subject_id, "splitter", "set_paused"),
                 %{}
               ),
               401
             )
  end

  test "contract routes reject signed-in wrong-wallet access across job, subject, and prepare flows",
       %{
         conn: conn,
         wrong_human: wrong_human
       } do
    conn = signed_in_conn(conn, wrong_human)
    subject_id = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    assert %{"ok" => false, "error" => %{"code" => "contract_scope_forbidden"}} =
             json_response(get(conn, contracts_job_path("job_contracts")), 403)

    assert %{"ok" => false, "error" => %{"code" => "contract_scope_forbidden"}} =
             json_response(get(conn, contracts_subject_path(subject_id)), 403)

    assert %{"ok" => false, "error" => %{"code" => "contract_scope_forbidden"}} =
             json_response(
               post(
                 conn,
                 contracts_job_prepare_path("job_contracts", "strategy", "migrate"),
                 %{}
               ),
               403
             )

    assert %{"ok" => false, "error" => %{"code" => "contract_scope_forbidden"}} =
             json_response(
               post(conn, contracts_subject_prepare_path(subject_id, "splitter", "set_paused"), %{
                 "paused" => "true"
               }),
               403
             )
  end

  test "removed fee mutation actions return unsupported action errors", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    assert %{"ok" => false, "error" => %{"code" => "unsupported_contract_action"}} =
             json_response(
               post(
                 conn,
                 contracts_job_prepare_path("job_contracts", "fee_registry", "set_hook_enabled"),
                 %{"enabled" => "false"}
               ),
               422
             )

    assert %{"ok" => false, "error" => %{"code" => "unsupported_contract_action"}} =
             json_response(
               post(
                 conn,
                 contracts_job_prepare_path("job_contracts", "fee_vault", "set_hook"),
                 %{"hook" => "0x4444444444444444444444444444444444444444"}
               ),
               422
             )

    assert %{"ok" => false, "error" => %{"code" => "unsupported_contract_action"}} =
             json_response(
               post(
                 conn,
                 contracts_subject_prepare_path(
                   "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                   "splitter",
                   "set_protocol_skim_bps"
                 ),
                 %{"skim_bps" => "250"}
               ),
               422
             )
  end

  test "admin route returns configured contract surface for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    conn = get(conn, contracts_admin_path())

    assert %{
             "ok" => true,
             "admin_contracts" => %{"revenue_share_factory" => %{"address" => address}}
           } =
             json_response(conn, 200)

    assert address == "0x1111111111111111111111111111111111111111"
  end

  test "job route returns launch contract stack state for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    conn = get(conn, contracts_job_path("job_contracts"))

    assert %{
             "ok" => true,
             "job" => %{"job_id" => "job_contracts"},
             "strategy" => %{"address" => strategy}
           } =
             json_response(conn, 200)

    assert strategy == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  end

  test "subject route returns subject contract state for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      get(
        conn,
        contracts_subject_path(
          "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )
      )

    assert %{
             "ok" => true,
             "subject" => %{
               "subject_id" =>
                 "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
               "splitter_address" => splitter
             },
             "registry" => %{"address" => registry}
           } = json_response(conn, 200)

    assert splitter == "0x9999999999999999999999999999999999999999"
    assert registry == "0x2222222222222222222222222222222222222222"
  end

  test "job prepare route returns prepared payload for strategy migration", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)
    conn = post(conn, contracts_job_prepare_path("job_contracts", "strategy", "migrate"), %{})

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "strategy",
               "action" => "migrate",
               "tx_request" => %{"data" => "0x8fd3ab80"}
             }
           } = json_response(conn, 200)
  end

  test "job prepare route returns prepared payload for vesting beneficiary rotation", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      post(
        conn,
        contracts_job_prepare_path("job_contracts", "vesting", "propose_beneficiary_rotation"),
        %{"beneficiary" => "0x1111111111111111111111111111111111111111"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "action" => "propose_beneficiary_rotation",
               "tx_request" => %{"data" => "0xc178cb2d"}
             }
           } = json_response(conn, 200)
  end

  test "subject prepare route returns prepared payload for splitter pause", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      post(
        conn,
        contracts_subject_prepare_path(
          "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "splitter",
          "set_paused"
        ),
        %{"paused" => "true"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "splitter",
               "action" => "set_paused",
               "tx_request" => %{"data" => "0x16c38b3c"}
             }
           } = json_response(conn, 200)
  end

  test "subject prepare route returns prepared payload for treasury sweep and safe sync", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    sweep_conn =
      post(
        conn,
        contracts_subject_prepare_path(
          "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "splitter",
          "sweep_treasury_residual"
        ),
        %{"amount" => "7"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "action" => "sweep_treasury_residual",
               "tx_request" => %{"data" => "0xe37459b1"}
             }
           } = json_response(sweep_conn, 200)

    rotate_conn =
      post(
        conn,
        contracts_subject_prepare_path(
          "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "registry",
          "rotate_safe"
        ),
        %{"new_safe" => "0x5555555555555555555555555555555555555555"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "action" => "rotate_safe",
               "tx_request" => %{"data" => "0xdbf6fd39"}
             }
           } = json_response(rotate_conn, 200)
  end

  test "admin prepare route returns a prepared transaction payload for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    conn =
      post(
        conn,
        contracts_admin_prepare_path("revenue_share_factory", "set_authorized_creator"),
        %{"account" => "0x1111111111111111111111111111111111111111", "enabled" => "true"}
      )

    assert %{
             "ok" => true,
             "prepared" => %{
               "resource" => "revenue_share_factory",
               "action" => "set_authorized_creator",
               "tx_request" => %{"data" => "0xe1434f4e"}
             }
           } = json_response(conn, 200)
  end

  test "prepare routes translate stable contract errors for the signed-in owner", %{
    conn: conn,
    human: human
  } do
    conn = signed_in_conn(conn, human)

    invalid_address_conn =
      post(conn, contracts_job_prepare_path("job_invalid_address", "strategy", "migrate"), %{})

    assert %{
             "error" => %{
               "code" => "invalid_address",
               "message" => "Address is invalid"
             }
           } = json_response(invalid_address_conn, 422)

    forbidden_conn =
      post(
        conn,
        contracts_subject_prepare_path("subject_forbidden", "splitter", "set_paused"),
        %{"paused" => "true"}
      )

    assert %{
             "error" => %{
               "code" => "contract_scope_forbidden",
               "message" => "Contract action is not allowed"
             }
           } = json_response(forbidden_conn, 403)

    invalid_uint_conn =
      post(conn, contracts_admin_prepare_path("broken", "set_authorized_creator"), %{})

    assert %{
             "error" => %{
               "code" => "invalid_amount",
               "message" => "Amount must be a whole onchain unit"
             }
           } = json_response(invalid_uint_conn, 422)
  end
end
