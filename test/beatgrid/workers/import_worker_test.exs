defmodule Beatgrid.Workers.ImportWorkerTest do
  # async: false — overrides the global :library_root app env.
  use Beatgrid.DataCase, async: false, oban: true

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Workers.{EnrichWorker, ImportWorker}

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
  test "imports the items with overrides and broadcasts progress", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    file = Path.join(src, "song.mp3")
    File.write!(file, "bytes")
    stub_healthy()

    Library.subscribe_import()

    items = [%{"source_path" => file, "artist" => "Djavan", "title" => "Sina"}]

    assert {:ok, %{imported: 1, skipped: 0}} =
             perform_job(ImportWorker, %{"items" => items, "batch_id" => "b1"})

    created = Tracks.get_by_path("_Inbox/song.mp3")
    assert created.tag_artist == "Djavan"
    assert created.tag_title == "Sina"

    assert_receive {:import_progress, %{batch_id: "b1", status: :done, imported: 1}}

    # No Soundcharts chain when the opt-in is absent.
    refute_enqueued(worker: EnrichWorker)
  end

  @tag :tmp_dir
  test "chains EnrichWorker (scope pending) when resolve_soundcharts is set", %{tmp_dir: root} do
    src = Path.join(root, "src")
    File.mkdir_p!(src)
    file = Path.join(src, "song.mp3")
    File.write!(file, "bytes")
    stub_healthy()

    items = [%{"source_path" => file, "artist" => "", "title" => ""}]

    assert {:ok, %{imported: 1}} =
             perform_job(ImportWorker, %{
               "items" => items,
               "batch_id" => "b2",
               "resolve_soundcharts" => true
             })

    assert_enqueued(worker: EnrichWorker, args: %{"scope" => "pending"})
  end
end
