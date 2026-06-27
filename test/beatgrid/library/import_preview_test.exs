defmodule Beatgrid.Library.ImportPreviewTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false

  import Mox

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks

  setup :verify_on_exit!

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
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
    assert length(rows) == 2

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
end
