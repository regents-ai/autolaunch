defmodule Autolaunch.LaunchDraftImageStorageTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias Autolaunch.LaunchDraftImageStorage

  test "PNG, JPEG, and WebP require matching complete signatures" do
    assert {:ok, "image/png"} = LaunchDraftImageStorage.validate(png(), "image/png")
    assert {:ok, "image/jpeg"} = LaunchDraftImageStorage.validate(jpeg(), "image/jpeg")
    assert {:ok, "image/webp"} = LaunchDraftImageStorage.validate(webp(), "image/webp")

    assert {:ok, "image/webp"} =
             LaunchDraftImageStorage.validate(animated_webp(), "image/webp")

    assert {:error, :invalid_image} = LaunchDraftImageStorage.validate(png(), "image/jpeg")
    assert {:error, :invalid_image} = LaunchDraftImageStorage.validate(jpeg(), "image/webp")
    assert {:error, :invalid_image} = LaunchDraftImageStorage.validate(webp(), "image/png")

    assert {:error, :invalid_image} =
             LaunchDraftImageStorage.validate("<svg></svg>", "image/svg+xml")

    assert {:error, :invalid_image} =
             LaunchDraftImageStorage.validate(binary_part(png(), 0, 20), "image/png")

    assert {:error, :invalid_image} =
             LaunchDraftImageStorage.validate(binary_part(jpeg(), 0, 5), "image/jpeg")

    assert {:error, :invalid_image} =
             LaunchDraftImageStorage.validate(
               binary_part(webp(), 0, byte_size(webp()) - 1),
               "image/webp"
             )

    assert {:ok, "image/png"} =
             LaunchDraftImageStorage.validate(exact_limit_png(), "image/png")

    assert {:ok, "image/jpeg"} =
             LaunchDraftImageStorage.validate(progressive_jpeg(), "image/jpeg")

    assert {:error, :image_too_large} =
             LaunchDraftImageStorage.validate(
               String.duplicate("x", 2_097_153),
               "image/png"
             )
  end

  test "marker-shaped invalid files cannot consume the account's image slot" do
    actor = actor!("marker-shaped")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    for {bytes, type, filename} <- [
          {marker_png(), "image/png", "fake.png"},
          {marker_jpeg(), "image/jpeg", "fake.jpg"},
          {marker_webp(), "image/webp", "fake.webp"}
        ] do
      assert {:error, :invalid_image} =
               LaunchDraftImageStorage.validate(bytes, type)

      assert {:error, :invalid_image} = store(draft, bytes, type, filename, actor)
      assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    end

    assert {:ok, %{image: image}} = store(draft, png(), "image/png", "real.png", actor)
    assert image.digest == :crypto.hash(:sha256, png()) |> Base.encode16(case: :lower)
  end

  test "structurally plausible but decoder-invalid files cannot consume the image slot" do
    actor = actor!("decoder-invalid")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    for {bytes, type, filename} <- [
          {decoder_invalid_jpeg(), "image/jpeg", "damaged.jpg"},
          {decoder_invalid_webp(), "image/webp", "damaged.webp"}
        ] do
      assert {:error, :invalid_image} = LaunchDraftImageStorage.validate(bytes, type)
      assert {:error, :invalid_image} = store(draft, bytes, type, filename, actor)
      assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    end

    assert {:ok, %{image: image}} = store(draft, webp(), "image/webp", "valid.webp", actor)
    assert image.content_type == "image/webp"
  end

  test "animated WebP validates every frame before consuming the image slot" do
    actor = actor!("animated-webp")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)
    corrupt = corrupt_later_frame_webp()

    assert {:ok, {first_page, _flags}} =
             Vix.Vips.Operation.webpload_buffer(corrupt,
               access: :VIPS_ACCESS_SEQUENTIAL,
               "fail-on": :VIPS_FAIL_ON_WARNING,
               n: 1
             )

    assert {:ok, _average} = Vix.Vips.Operation.avg(first_page)

    assert {:error, :invalid_image} =
             LaunchDraftImageStorage.validate(corrupt, "image/webp")

    assert {:error, :invalid_image} =
             store(draft, corrupt, "image/webp", "corrupt-animation.webp", actor)

    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)

    assert {:ok, first} =
             store(draft, animated_webp(), "image/webp", "animation.webp", actor)

    assert first.image.byte_size == byte_size(animated_webp())

    # An occupied slot is decided under the owner lock before a different file
    # reaches the decoder. If this were decoded first, it would be invalid_image.
    assert {:error, :image_limit_reached} =
             store(
               first.draft,
               corrupt,
               "image/webp",
               "different-corrupt-animation.webp",
               actor
             )

    assert {:ok, only} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert only.id == first.image.id
  end

  test "a forced failure after image creation and before attachment rolls the image back" do
    actor = actor!("rollback")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:error, :forced_before_attachment} =
             Autolaunch.Repo.transaction(fn ->
               assert {:ok, _image} =
                        Autolaunch.create_launch_draft_image(
                          png(),
                          "image/png",
                          "rollback.png",
                          draft.id,
                          actor: actor
                        )

               Autolaunch.Repo.rollback(:forced_before_attachment)
             end)

    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert {:ok, [persisted]} = Autolaunch.list_my_launch_drafts(actor: actor)
    assert is_nil(persisted.launch_draft_image_id)
    assert is_nil(persisted.image)
  end

  test "image dimensions are advisory and a valid 1 by 1 PNG is accepted" do
    actor = actor!("non-400-image")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, %{image: image}} =
             LaunchDraftImageStorage.store_and_attach(
               draft,
               png(),
               "image/png",
               "one-pixel.png",
               actor
             )

    assert image.content_type == "image/png"
    assert image.byte_size == byte_size(png())
    assert image.original_filename == "one-pixel.png"
    assert image.launch_draft_id == draft.id
  end

  test "one immutable image is stored transactionally, attached, and exact repeats deduplicate" do
    actor = actor!("one-image")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, first} =
             store(draft, png(), "image/png", "launch.png", actor)

    assert first.reused? == false
    assert first.image.byte_size == byte_size(png())
    assert first.draft.launch_draft_image_id == first.image.id
    assert first.draft.image == LaunchDraftImageStorage.public_url(first.image)
    assert byte_size(first.draft.image) <= 256

    assert {:ok, repeat} =
             store(first.draft, png(), "image/png", "renamed.png", actor)

    assert repeat.reused?
    assert repeat.image.id == first.image.id
    assert repeat.draft.image == first.draft.image
    assert {:ok, only} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert only.id == first.image.id
    assert only.original_filename == "launch.png"
  end

  test "a different second image fails without replacing or deleting the first" do
    actor = actor!("second-refused")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, first} =
             store(draft, png(), "image/png", "first.png", actor)

    assert {:error, :image_limit_reached} =
             store(first.draft, jpeg(), "image/jpeg", "second.jpg", actor)

    assert {:ok, persisted} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
    assert persisted.id == first.image.id
    assert {:ok, [saved_draft]} = Autolaunch.list_my_launch_drafts(actor: actor)
    assert saved_draft.launch_draft_image_id == first.image.id
    assert saved_draft.image == first.draft.image
  end

  test "concurrent different first uploads still create only one immutable owner row" do
    actor = actor!("concurrent-first")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)
    parent = self()

    upload = fn bytes, type, filename ->
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> store(draft, bytes, type, filename, actor))
      end)
    end

    png_upload = upload.(png(), "image/png", "first.png")
    jpeg_upload = upload.(jpeg(), "image/jpeg", "second.jpg")

    assert_receive {:ready, png_pid}
    assert_receive {:ready, jpeg_pid}
    send(png_pid, :go)
    send(jpeg_pid, :go)

    results = [Task.await(png_upload), Task.await(jpeg_upload)]

    assert Enum.count(results, &match?({:ok, _stored}, &1)) == 1
    assert Enum.count(results, &match?({:error, :image_limit_reached}, &1)) == 1
    assert {:ok, _only} = Autolaunch.get_my_launch_draft_image(draft.id, actor: actor)
  end

  test "the same bytes are private per Human and cross-account attachment is refused" do
    owner = actor!("image-owner")
    other = actor!("image-other")
    draft = Autolaunch.create_launch_draft!(%{}, actor: owner)

    assert {:error, :image_unavailable} =
             store(draft, png(), "image/png", "owner.png", other)

    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: owner)
    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(draft.id, actor: other)

    assert {:ok, owner_image} =
             store(draft, png(), "image/png", "owner.png", owner)

    other_draft = Autolaunch.create_launch_draft!(%{}, actor: other)

    assert {:ok, other_image} =
             store(other_draft, png(), "image/png", "other.png", other)

    refute owner_image.image.id == other_image.image.id
    assert owner_image.image.digest == other_image.image.digest
  end

  test "the actorless public read requires exact UUID and full digest" do
    actor = actor!("public")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, %{image: image}} =
             store(draft, webp(), "image/webp", "public.webp", actor)

    assert {:ok, public} =
             Autolaunch.get_public_launch_draft_image(image.id, image.digest, actor: nil)

    assert public.bytes == webp()
    assert public.content_type == "image/webp"

    wrong = String.duplicate("0", 64)
    assert {:ok, nil} = Autolaunch.get_public_launch_draft_image(image.id, wrong, actor: nil)
    assert {:error, %Ash.Error.Invalid{}} = Autolaunch.get_my_launch_draft_image(draft.id)
  end

  test "the Ash create boundary derives digest and size and rejects malformed bytes" do
    actor = actor!("derived-boundary")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, image} =
             Autolaunch.create_launch_draft_image(
               png(),
               "image/png",
               "derived.png",
               draft.id,
               actor: actor
             )

    assert image.byte_size == byte_size(png())
    assert image.digest == :crypto.hash(:sha256, png()) |> Base.encode16(case: :lower)

    other = actor!("malformed-boundary")
    other_draft = Autolaunch.create_launch_draft!(%{}, actor: other)

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.create_launch_draft_image(
               binary_part(png(), 0, byte_size(png()) - 1),
               "image/png",
               "truncated.png",
               other_draft.id,
               actor: other
             )
  end

  test "the Ash and database boundaries refuse a second row and cross-draft attachment" do
    actor = actor!("resource-boundary")
    draft = Autolaunch.create_launch_draft!(%{}, actor: actor)

    assert {:ok, %{image: _image}} =
             store(draft, png(), "image/png", "first.png", actor)

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.create_launch_draft_image(
               jpeg(),
               "image/jpeg",
               "second.jpg",
               draft.id,
               actor: actor
             )

    filename_actor = actor!("filename-boundary")
    filename_draft = Autolaunch.create_launch_draft!(%{}, actor: filename_actor)

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.create_launch_draft_image(
               png(),
               "image/png",
               String.duplicate("x", 256),
               filename_draft.id,
               actor: filename_actor
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.create_launch_draft_image(
               png(),
               "image/png",
               String.duplicate("é", 128),
               filename_draft.id,
               actor: filename_actor
             )
  end

  test "the database boundary refuses an image whose draft belongs to another Human" do
    owner = actor!("provenance-owner")
    other = actor!("provenance-other")
    owner_draft = Autolaunch.create_launch_draft!(%{}, actor: owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Autolaunch.create_launch_draft_image(
               png(),
               "image/png",
               "wrong-owner.png",
               owner_draft.id,
               actor: other
             )

    assert {:ok, nil} = Autolaunch.get_my_launch_draft_image(owner_draft.id, actor: other)
  end

  defp actor!(suffix) do
    account =
      Accounts.register_verified!(
        "did:privy:launch-image:#{suffix}:#{Elixir.System.unique_integer([:positive])}",
        nil,
        [],
        actor: %System{}
      )

    %Human{human_account_id: account.id}
  end

  defp store(draft, bytes, type, filename, actor),
    do: LaunchDraftImageStorage.store_and_attach(draft, bytes, type, filename, actor)

  defp png,
    do: File.read!("test/support/fixtures/launch-draft.png")

  defp jpeg, do: File.read!("test/support/fixtures/launch-draft.jpg")

  defp webp do
    "UklGRlIBAABXRUJQVlA4WAoAAAAQAAAADwAADwAAQUxQSHwAAAABgJpt27LsxgZwt0qEGZjBR/BEJUF0r1RtOoBDJ7u7w+/yvitExAQAYBhrm7dl3cXF35nPv/ceJgBG4JMwxwEMJ5LPBMSHT+IPnfeTMlKiafRoJn2aa5FmYaep8A4UNrjJOmwwsiRDDQCW//Vr9/ZZluNPbbAx6Jd8egAAVlA4ILAAAADQAgCdASoQABAAAgA0JbACdBigF8M3WZNkeTSToAIoAPvSwALo4z2kMbTx/2S7+Uvxn9Voq6r6SlcWNcYUnQmQW1zSvgidLCqL3q9yyVJbK/NRgpGT3c9bJfhhUBXTWekpatEcRp/NrlOTrD/KMOFz2W2sZi+r+TtRwqfZQ3Pd4/esYCwxAf3CfYo59EQkv9PT/ocMZ2/MhitKyKD4n8utXRofdx28t5M+KhKv19CAAA=="
    |> Base.decode64!()
  end

  defp animated_webp do
    "UklGRk4EAABXRUJQVlA4WAoAAAASAAAADwAADwAAQU5JTQYAAAD/////AABBTk1GDAIAAAAAAAAAAA8AAA8AAGQAAAJWUDhM9AEAAC8PwAMQV+SgjSRHql44z5/KY3gCOXQXDcdtG0mSauY9s0f+wWxC+7yry3LYto0kybvYJq7/lq6S/24mltvYtlVl/Y9LTv81MLRCRujy3TWAQIRMKIFqPRb1v7THIpTKaFOmVO2h+v82U121GZva1Pf1pUDdnw+bUn1fPxuBlnKk+n3//v9lq37fpWtDdFXX9vssKMF6gARRHRmBFJvCUm3UHu1Bxr8LSsPIlAohWA9R1ATKWKhHhSkFChmEHlwDIRAACTABZWABrKjM4jbwBCIBsgYiYADawBYIIaXFCETBHZILLaROGYAHyR1oQwJgioxWvkB0ak6HXKkrJkk/cQ+rPvSfimwBR6rekHH2st0znLUb0eV+RLfjNvNgunIPAGHbtuOp0u2ZbdSybS/b7s627aZc988eIvo/ASSV9wdL86s7ty9MfIzhuoqGscnozR9JxcVUhlNEdJmDOPohH8arc3wS7+jDKb/XK0tUktg/s/B0NdRk0Jj1dqPWpZVyXO51NIox1B0eaQvViwdb29NVYgy1loWKOiOiHliJoV2ModKsUFptWKR57hAT5lRa1u4QzNMG3LaAyZsuurH9t/XeHoskzcUjr4GgNYG2YOb9l8oToL+mOD+7sAvLzyT/z2enRoHFeey+MuHX2eZGbO/jkyQBQU5NRg4CAAAAAAAAAAAPAAAPAABkAAACVlA4TPYBAAAvD8ADEFfkIJIkSanqfe4OMIAG/FtBzrYNx40kSUpm9fTuAk8cwn9j7jfbDtu2kSTJmdm9t5Lrv6Vr4rPb2LZVZX3/SE7/NTC0QkRKxPDdNYCTISxlcghU6ZFobNvokQilMkqFCdXooZr7YmKsSI1UpGLfLhSoz/0pFap9O6UESsKSah2HuW1ZsY5trAUxVoy1rMuGEqQHSFA1SkYgRSowVCmNHqMHGbMDQsvIhAohSA9RVQTK2Kl3hQkFCtmEFUyBEAiACjiAvhABCdMTLIFCgKRAAWzAXMiBENo77EBRvCCtMEPHjgF4k36BufQEwsrq9AcUZ+Zx6Jv5lKT1Fa+wx0P+nepZ8K9jgtIPsse88vcJv9GT4v/8F9/f++TB8eMVAKJt26abE9soUtt2atvdNVPbDOt2f3bwDRH9nwCSivuDlcX13ZsXJj7GaENV08R05PaPpPJiJsspIrrsYRz9kA+TtXlpEu8YwCm/o9VlKkmcPrf0dDXSYtCY9Xaj1qWVSlwGuprFGOwNjXUEG8WD7Z3ZGjEG2yuCJd1hUQ+txdApxmB5TjCjPiTSunCIKXMqbRt38BdofW6bz+TNFN3E/lu0v88iSfPxyGvAb02gLZp7/6XiBBisKy3MLe7B6jPJ//P5mXFgeRF7r0z4dba1GQt8fJIk"
    |> Base.decode64!()
  end

  defp corrupt_later_frame_webp do
    valid = animated_webp()
    <<prefix::binary-size(800), _damaged::binary-size(40), suffix::binary>> = valid
    prefix <> :binary.copy(<<0>>, 40) <> suffix
  end

  # These payloads satisfy the former format/container parser but fail
  # while libvips pulls their damaged pixels through the decoder.
  defp decoder_invalid_jpeg do
    valid = jpeg()
    binary_part(valid, 0, 1_000) <> <<255, 217>>
  end

  defp decoder_invalid_webp do
    "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AA/vuUAAA="
    |> Base.decode64!()
    |> binary_part(0, 42)
  end

  defp exact_limit_png do
    base = png()
    prefix = binary_part(base, 0, byte_size(base) - 12)
    iend = binary_part(base, byte_size(base) - 12, 12)
    data = :binary.copy(<<0>>, 2_097_152 - byte_size(base) - 12)
    chunk = <<byte_size(data)::32, "tEXt", data::binary, :erlang.crc32("tEXt" <> data)::32>>
    image = prefix <> chunk <> iend
    2_097_152 = byte_size(image)
    image
  end

  defp progressive_jpeg do
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAAQABADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUAQEAAAAAAAAAAAAAAAAAAAAE/9oADAMBAAIQAxAAAAGMBv8A/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQABBQIf/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQAGPwIf/8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQABPyEf/9oADAMBAAIAAwAAABD3/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAwEBPxB//8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAgBAgEBPxB//8QAFBABAAAAAAAAAAAAAAAAAAAAIP/aAAgBAQABPxAf/9k="
    |> Base.decode64!()
  end

  defp marker_png do
    ihdr = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    compressed = :zlib.compress(<<0, 0>>)

    <<137, "PNG\r\n", 26, 10>> <>
      png_chunk("IHDR", ihdr) <>
      png_chunk("IDAT", compressed) <>
      png_chunk("IEND", <<>>)
  end

  defp marker_jpeg,
    do: <<255, 216, 255, 219, 0, 3, 0, 255, 194, 0, 2, 255, 218, 0, 2, 255, 217>>

  defp marker_webp do
    chunk = <<"VP8 ", 10::little-32, 0::size(80)>>
    <<"RIFF", byte_size(chunk) + 4::little-32, "WEBP", chunk::binary>>
  end

  defp png_chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
