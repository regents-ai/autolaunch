defmodule Autolaunch.SubjectTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport

  @unsafe_subject_ids [
    slash: "subject/slash",
    query: "subject?query",
    fragment: "subject#fragment",
    percent: "subject%encoded",
    space: "subject identity",
    unicode: "subject-é",
    too_long: String.duplicate("a", 129)
  ]

  test "anonymous reads use the canonical identity for tokens" do
    subject = subject!()

    auction =
      TestSupport.project_auction(
        title: "Subject token auction",
        state: :graduated,
        opened_at: DateTime.utc_now(),
        treasury_address: subject.treasury_address
      )

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        subject_id: subject.subject_id,
        name: "Subject Token",
        symbol: "SUBJ",
        summary: "Linked by canonical subject identity.",
        graduated_at: DateTime.utc_now()
      )

    assert {:ok, subjects} = Autolaunch.list_subjects()
    assert subject.subject_id in Enum.map(subjects, & &1.subject_id)

    assert {:ok, public} = Autolaunch.get_public_subject(subject.subject_id)
    assert public.subject_id == "subject:resource"
    assert public.protocol_fee_usdc_total_raw == "12000000"
    assert public.regent_emission_total_raw == "3400000000000000000"
    assert public.pending_buyback_usdc_raw == "5000000"

    assert {:ok, [related]} = Autolaunch.list_subject_tokens(subject.subject_id)
    assert related.id == token.id
    assert {:ok, nil} = Autolaunch.get_public_subject("subject:missing")
  end

  test "canonical subject identities reject every value unsafe for the public route" do
    for {unsafe_class, subject_id} <- @unsafe_subject_ids do
      assert {:error, %Ash.Error.Invalid{} = error} = project_subject(subject_id)

      message = Exception.message(error)
      assert message =~ "subject_id", "#{unsafe_class} did not identify the invalid field"

      assert message =~ "must match the pattern" or
               message =~ "length must be less than or equal to 128",
             "#{unsafe_class} did not explain the canonical ID format"
    end
  end

  test "subject projection requires the real system actor" do
    for actor <- [nil, %{role: :system}, %{role: :human, human_account_id: 1}] do
      assert {:error, %Ash.Error.Forbidden{}} =
               project_subject("subject:forbidden", actor: actor)
    end
  end

  describe "CANONICAL_RECEIVER_IS_PROJECTED_NOT_IMPORTED" do
    test "the canonical receiver starts absent and only a SystemActor may set it" do
      subject = subject!("subject:canonical-receiver")
      assert is_nil(subject.canonical_receiver_address)

      receiver = "0x9999999999999999999999999999999999999999"

      assert {:ok, projected} =
               Autolaunch.set_subject_canonical_receiver(subject, receiver, actor: %System{})

      assert projected.canonical_receiver_address == receiver

      for actor <- [nil, %Autolaunch.Actors.Human{human_account_id: 1}] do
        assert {:error, _forbidden} =
                 Autolaunch.set_subject_canonical_receiver(
                   projected,
                   "0x1010101010101010101010101010101010101010",
                   actor: actor
                 )
      end

      assert {:ok, unchanged} =
               Autolaunch.get_public_subject(subject.subject_id, actor: nil)

      assert unchanged.canonical_receiver_address == receiver
    end

    test "projection does not invent a canonical receiver" do
      assert {:ok, subject} = project_subject("subject:import-unchanged")
      assert is_nil(subject.canonical_receiver_address)
      assert subject.treasury_address == "0x6666666666666666666666666666666666666666"
    end
  end

  defp subject!(subject_id \\ "subject:resource") do
    case project_subject(subject_id) do
      {:ok, subject} -> subject
      {:error, error} -> raise error
    end
  end

  defp project_subject(subject_id, opts \\ []) do
    Autolaunch.project_lab_subject(
      %{
        subject_id: subject_id,
        subject_kind: "agent",
        chain_id: 8453,
        token_address: "0x3333333333333333333333333333333333333333",
        splitter_address: "0x4444444444444444444444444444444444444444",
        ingress_address: "0x5555555555555555555555555555555555555555",
        treasury_address: "0x6666666666666666666666666666666666666666",
        factory_address: "0x7777777777777777777777777777777777777777",
        creator_address: "0x8888888888888888888888888888888888888888",
        staker_pool_bps: 1500,
        protocol_skim_bps_snapshot: 250,
        current_protocol_skim_bps: 200,
        protocol_fee_usdc_total_raw: "12000000",
        regent_emission_total_raw: "3400000000000000000",
        pending_buyback_usdc_raw: "5000000"
      },
      actor: Keyword.get(opts, :actor, %System{})
    )
  end
end
