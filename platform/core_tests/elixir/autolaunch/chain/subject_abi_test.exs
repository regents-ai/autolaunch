defmodule Autolaunch.Chain.SubjectAbiTest do
  use ExUnit.Case, async: true

  alias Autolaunch.Chain.SubjectAbi

  @calls [:stake, :unstake, :claim, :claim_all, :pay, :sweep, :set_receiver_note]
  @events [:payment_routed, :receiver_note_updated]

  test "every selector and topic is the keccak of its declared signature" do
    for id <- @calls do
      assert SubjectAbi.selector(id) == binary_part(keccak(SubjectAbi.signature(id)), 0, 10)
    end

    for id <- @events do
      assert SubjectAbi.selector(id) == keccak(SubjectAbi.signature(id))
    end
  end

  test "a sweep names only the token, as the deployed receiver does" do
    token = "0x" <> String.duplicate("ab", 20)

    assert SubjectAbi.encode_sweep(token) ==
             "0x01681a62" <> String.duplicate("0", 24) <> String.duplicate("ab", 20)
  end

  defp keccak(text),
    do: "0x" <> Base.encode16(:jose_jwa_sha3.keccak(1088, 512, text, 1, 32), case: :lower)
end
