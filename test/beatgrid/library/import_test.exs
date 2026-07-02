defmodule Beatgrid.Library.ImportTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks

  setup :isolate_library_root

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
    end

    :ok
  end

  defp stub_healthy do
    stub(Beatgrid.Audio.Mock, :read_metadata, fn _path ->
      {:ok, %Metadata{title: "T", artist: "A", bitrate_kbps: 320, duration_ms: 200_000}}
    end)
  end

  @tag :tmp_dir
  test "copies source audio into _Inbox, records provenance, skips exact duplicates", %{
    tmp_dir: root
  } do
    source = Path.join(root, "src")
    File.mkdir_p!(Path.join(source, "MPBzera"))
    File.mkdir_p!(Path.join(source, "Escrito"))
    # same bytes in two playlists → a duplicate
    File.write!(Path.join(source, "MPBzera/Disritmia.mp3"), "same-bytes")
    File.write!(Path.join(source, "Escrito/Disritmia.mp3"), "same-bytes")
    File.write!(Path.join(source, "MPBzera/Ben.mp3"), "ben-bytes")

    stub_healthy()

    assert {:ok, %{imported: 2, skipped: 1}} = Library.import_from(source)

    # originals untouched
    assert File.exists?(Path.join(source, "MPBzera/Disritmia.mp3"))
    assert [_, _] = File.ls!(Path.join(root, "_Inbox"))

    tracks = Tracks.list_by(status: :present)
    assert [_, _] = tracks

    disritmia = Enum.find(tracks, &(&1.filename == "Disritmia.mp3"))
    assert disritmia.source_playlist in ["MPBzera", "Escrito"]
    assert disritmia.genre_folder == nil
    assert String.starts_with?(disritmia.rel_path, "_Inbox/")
  end

  @tag :tmp_dir
  test "does not re-import a file already in the library", %{tmp_dir: root} do
    source = Path.join(root, "src")
    File.mkdir_p!(Path.join(source, "MPBzera"))
    File.write!(Path.join(source, "MPBzera/Ben.mp3"), "ben")
    stub_healthy()

    assert {:ok, %{imported: 1, skipped: 0}} = Library.import_from(source)
    assert {:ok, %{imported: 0, skipped: 1}} = Library.import_from(source)
    assert Tracks.count() == 1
  end

  describe "import_files/3" do
    @tag :tmp_dir
    test "copies new files with reviewed overrides, skips dup, broadcasts progress", %{
      tmp_dir: root
    } do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      new_file = Path.join(src, "novo.mp3")
      dup_file = Path.join(src, "ja_existe.mp3")
      File.write!(new_file, "new-bytes")
      File.write!(dup_file, "dup-bytes")

      stub_healthy()

      # A track whose content hash matches dup_file already exists → it's skipped.
      dup_sha = :sha256 |> :crypto.hash("dup-bytes") |> Base.encode16(case: :lower)

      insert(:track,
        status: :present,
        content_sha256: dup_sha,
        rel_path: "_Inbox/ja_existe.mp3",
        filename: "ja_existe.mp3"
      )

      Library.subscribe_import()

      items = [
        %{"source_path" => new_file, "artist" => "Djavan", "title" => "Sina"},
        %{"source_path" => dup_file, "artist" => "X", "title" => "Y"}
      ]

      assert %{imported: 1, skipped: 1} = Library.import_files(items, "b1")

      # The new track exists in _Inbox with the OVERRIDE artist/title.
      created = Tracks.get_by_path("_Inbox/novo.mp3")
      assert created
      assert created.tag_artist == "Djavan"
      assert created.tag_title == "Sina"
      assert created.source_playlist == "import"
      assert created.status == :present
      assert File.exists?(Path.join(root, "_Inbox/novo.mp3"))

      # Originals are left untouched.
      assert File.exists?(new_file)
      assert File.exists?(dup_file)

      assert_receive {:import_progress, %{batch_id: "b1", status: :running, total: 2, done: 0}}
      assert_receive {:import_progress, %{batch_id: "b1", status: :done, imported: 1, skipped: 1}}
    end

    @tag :tmp_dir
    test "blank overrides keep the file's own tags", %{tmp_dir: root} do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      file = Path.join(src, "tagged.mp3")
      File.write!(file, "bytes")
      stub_healthy()

      items = [%{"source_path" => file, "artist" => "", "title" => ""}]
      assert %{imported: 1, skipped: 0} = Library.import_files(items, "b2")

      created = Tracks.get_by_path("_Inbox/tagged.mp3")
      # stub_healthy/0 tags are "A"/"T" — kept since overrides are blank.
      assert created.tag_artist == "A"
      assert created.tag_title == "T"
    end
  end
end
