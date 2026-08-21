defmodule Beatgrid.Library.ImportPreviewTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false

  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks

  setup :verify_on_exit!
  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    :ok
  end

  # One tagged file (artist+title in the tags) and one untagged file whose name
  # the heuristic can't split (no " - "), so it stays artist-less for the AI.
  defp stub_tags(tagged_name) do
    stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
      if String.ends_with?(path, tagged_name) do
        {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
      else
        {:ok, %Metadata{title: nil, artist: nil, duration_ms: 180_000}}
      end
    end)
  end

  @tag :tmp_dir
  test "previews proposed artist/title per file without writing anything", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "tagged-bytes")
    File.write!(Path.join(src, "anavitoria_trevo.mp3"), "untagged-bytes")

    stub_tags("Djavan - Sina.mp3")

    # The AI refines only the untagged (artist-less) row.
    expect(Beatgrid.AI.Mock, :complete, fn _prompt, _schema, _opts ->
      {:ok, %{"titles" => [%{"artist" => "Anavitória", "title" => "Trevo"}]}}
    end)

    inbox_before = File.ls!(Path.join(root, "_Inbox"))

    assert {:ok, rows} = Library.preview_import(src, ai: true)
    assert [_, _] = rows

    tagged = Enum.find(rows, &(&1.filename == "Djavan - Sina.mp3"))
    assert tagged.artist == "Djavan"
    assert tagged.title == "Sina"
    assert tagged.duration_ms == 211_000
    assert tagged.format == :mp3
    assert is_binary(tagged.sha256)
    refute tagged.duplicate

    untagged = Enum.find(rows, &(&1.filename == "anavitoria_trevo.mp3"))
    assert untagged.artist == "Anavitória"
    assert untagged.title == "Trevo"

    # SAFETY: zero writes — _Inbox untouched, originals intact, no tracks created.
    assert File.ls!(Path.join(root, "_Inbox")) == inbox_before
    assert File.exists?(Path.join(src, "Djavan - Sina.mp3"))
    assert Tracks.list_by() == []
  end

  @tag :tmp_dir
  test "without ai: keeps the heuristic split, no AI call", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Caetano Veloso - Sozinho.mp3"), "bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{title: nil, artist: nil, duration_ms: 200_000}}
    end)

    # No expect on AI.Mock — if parse_titles were called the mock would raise.
    assert {:ok, [row]} = Library.preview_import(src, ai: false)
    assert row.artist == "Caetano Veloso"
    assert row.title == "Sozinho"
  end

  @tag :tmp_dir
  test "flags files whose content already exists in the library as duplicate", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Ben.mp3"), "ben-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{title: "Ben", artist: "Jorge Ben", duration_ms: 200_000}}
    end)

    sha = :sha256 |> :crypto.hash("ben-bytes") |> Base.encode16(case: :lower)

    insert(:track,
      status: :present,
      content_sha256: sha,
      rel_path: "_Inbox/Ben.mp3",
      filename: "Ben.mp3"
    )

    assert {:ok, [row]} = Library.preview_import(src, ai: false)
    assert row.duplicate
  end

  @tag :tmp_dir
  test "flags a fuzzy near-dup (same artist+title, different hash) as near_dup", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "other-bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    # A present track with the SAME normalized artist+title but a DIFFERENT hash.
    insert(:track,
      status: :present,
      content_sha256: "a-different-hash",
      tag_artist: "Djavan",
      tag_title: "Sina",
      norm_artist: "djavan",
      norm_title: "sina",
      rel_path: "MPB/sina.mp3",
      filename: "sina.mp3"
    )

    assert {:ok, [row]} = Library.preview_import(src, ai: false)
    assert row.near_dup
    refute row.duplicate
  end

  @tag :tmp_dir
  test "does not flag near_dup when the artist+title differ", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "Djavan - Sina.mp3"), "bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    insert(:track,
      status: :present,
      content_sha256: "h",
      tag_artist: "Caetano Veloso",
      tag_title: "Sozinho",
      norm_artist: "caetano veloso",
      norm_title: "sozinho",
      rel_path: "MPB/sozinho.mp3",
      filename: "sozinho.mp3"
    )

    assert {:ok, [row]} = Library.preview_import(src, ai: false)
    refute row.near_dup
  end

  @tag :tmp_dir
  test "previews a single audio file", %{tmp_dir: root} do
    file = Path.join(root, "Djavan - Sina.mp3")
    File.write!(file, "bytes")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{title: "Sina", artist: "Djavan", duration_ms: 211_000}}
    end)

    assert {:ok, [row]} = Library.preview_import(file, ai: false)
    assert row.filename == "Djavan - Sina.mp3"
    assert row.artist == "Djavan"
  end

  @tag :tmp_dir
  test "returns {:error, :not_found} for a bogus path", %{tmp_dir: root} do
    assert {:error, :not_found} = Library.preview_import(Path.join(root, "nope"))
  end

  # The downloader hands out audio with video-container extensions: a .mpeg that
  # IS an mp3, an .mp4 that is aac-only (an .m4a in disguise). Judging by
  # extension alone made the import blind to both — the exact "0 novas / não é
  # áudio" the DJ hit on gig day.
  describe "container extensions carrying pure audio" do
    defp stub_containers do
      stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
        cond do
          String.ends_with?(path, ".mpeg") ->
            {:ok, %Metadata{format_name: "mp3", duration_ms: 159_533}}

          String.ends_with?(path, ".mp4") ->
            {:ok, %Metadata{format_name: "mov,mp4,m4a,3gp,3g2,mj2", duration_ms: 177_393}}

          true ->
            raise "probed a non-media file: #{path}"
        end
      end)
    end

    @tag :tmp_dir
    test "previews .mpeg/.mp4 files whose content is audio", %{tmp_dir: root} do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "Josy - Todo Mundo Bole.mpeg"), "mp3-bytes")
      File.write!(Path.join(src, "Savinho - Sorrindo e Cantando.mp4"), "aac-bytes")
      # Junk must never even be probed.
      File.write!(Path.join(src, "capa.jpg"), "jpg-bytes")

      stub_containers()

      assert {:ok, rows} = Library.preview_import(src, ai: false)
      assert length(rows) == 2

      josy = Enum.find(rows, &(&1.filename == "Josy - Todo Mundo Bole.mpeg"))
      assert josy.format == :mp3
      assert josy.artist == "Josy"
      assert josy.title == "Todo Mundo Bole"

      savinho = Enum.find(rows, &(&1.filename == "Savinho - Sorrindo e Cantando.mp4"))
      assert savinho.format == :m4a
      assert savinho.artist == "Savinho"
    end

    @tag :tmp_dir
    test "previews a single .mp4 file pasted directly", %{tmp_dir: root} do
      file = Path.join(root, "Savinho - Sorrindo e Cantando.mp4")
      File.write!(file, "aac-bytes")
      stub_containers()

      assert {:ok, [row]} = Library.preview_import(file, ai: false)
      assert row.artist == "Savinho"
      assert row.format == :m4a
    end

    @tag :tmp_dir
    test "excludes a container with no audio stream", %{tmp_dir: root} do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "Josy - Todo Mundo Bole.mpeg"), "mp3-bytes")
      File.write!(Path.join(src, "trailer.mp4"), "video-bytes")

      stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
        if String.ends_with?(path, ".mpeg"),
          do: {:ok, %Metadata{format_name: "mp3", duration_ms: 159_533}},
          else: {:error, :not_audio}
      end)

      assert {:ok, rows} = Library.preview_import(src, ai: false)
      assert [%{format: :mp3}] = rows
    end
  end
end
