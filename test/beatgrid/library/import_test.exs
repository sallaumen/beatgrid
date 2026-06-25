defmodule Beatgrid.Library.ImportTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks

  setup tags do
    if root = tags[:tmp_dir] do
      File.mkdir_p!(Path.join(root, "_Inbox"))
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
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
    assert length(File.ls!(Path.join(root, "_Inbox"))) == 2

    tracks = Tracks.list_by(status: :present)
    assert length(tracks) == 2

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
end
