defmodule Beatgrid.Library.ImportTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false, oban: true

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

    @tag :tmp_dir
    test "normalizes a lying extension on copy: .mpeg lands as .mp3, .mp4 as .m4a", %{
      tmp_dir: root
    } do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      josy = Path.join(src, "Josy - Todo Mundo Bole.mpeg")
      savinho = Path.join(src, "Savinho - Sorrindo e Cantando.mp4")
      File.write!(josy, "mp3-bytes")
      File.write!(savinho, "aac-bytes")

      stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
        if String.ends_with?(path, ".mpeg"),
          do: {:ok, %Metadata{format_name: "mp3", duration_ms: 159_533}},
          else: {:ok, %Metadata{format_name: "mov,mp4,m4a,3gp,3g2,mj2", duration_ms: 177_393}}
      end)

      items = [
        %{"source_path" => josy, "artist" => "Josy", "title" => "Todo Mundo Bole"},
        %{"source_path" => savinho, "artist" => "Savinho", "title" => "Sorrindo e Cantando"}
      ]

      assert %{imported: 2, skipped: 0} = Library.import_files(items, "b3")

      # The copy is byte-identical — only the name stops lying.
      assert File.read!(Path.join(root, "_Inbox/Josy - Todo Mundo Bole.mp3")) == "mp3-bytes"

      assert File.read!(Path.join(root, "_Inbox/Savinho - Sorrindo e Cantando.m4a")) ==
               "aac-bytes"

      assert %{format: :mp3} = Tracks.get_by_path("_Inbox/Josy - Todo Mundo Bole.mp3")
      assert %{format: :m4a} = Tracks.get_by_path("_Inbox/Savinho - Sorrindo e Cantando.m4a")

      # Originals untouched — import copies, never moves.
      assert File.exists?(josy)
      assert File.exists?(savinho)
    end

    @tag :tmp_dir
    test "queues the full analysis suite per imported track — no manual Painel sweep", %{
      tmp_dir: root
    } do
      src = Path.join(root, "src")
      File.mkdir_p!(src)
      file = Path.join(src, "nova.mp3")
      File.write!(file, "nova-bytes")
      dup = Path.join(src, "dup.mp3")
      File.write!(dup, "dup-bytes")
      stub_healthy()

      dup_sha = :sha256 |> :crypto.hash("dup-bytes") |> Base.encode16(case: :lower)

      insert(:track,
        status: :present,
        content_sha256: dup_sha,
        rel_path: "_Inbox/dup.mp3",
        filename: "dup.mp3"
      )

      items = [
        %{"source_path" => file, "artist" => "", "title" => ""},
        %{"source_path" => dup, "artist" => "", "title" => ""}
      ]

      assert %{imported: 1, skipped: 1} = Library.import_files(items, "b4")

      t = Tracks.get_by_path("_Inbox/nova.mp3")
      assert_enqueued(worker: Beatgrid.Workers.AnalyzeWorker, args: %{track_id: t.id})
      assert_enqueued(worker: Beatgrid.Workers.LoudnessWorker, args: %{track_id: t.id})
      assert_enqueued(worker: Beatgrid.Workers.MarkerAnalyzeWorker, args: %{track_id: t.id})

      # The skipped duplicate gets NO jobs — its library twin is already analyzed.
      refute_enqueued(worker: Beatgrid.Workers.AnalyzeWorker, args: %{track_id: nil})
      assert length(all_enqueued(worker: Beatgrid.Workers.AnalyzeWorker)) == 1
    end
  end
end
