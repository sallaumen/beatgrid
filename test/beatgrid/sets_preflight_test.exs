defmodule Beatgrid.SetsPreflightTest do
  # async: false — the check reads files from an isolated :library_root on disk.
  use Beatgrid.DataCase, async: false

  import Beatgrid.Factory

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Sets

  @moduletag :tmp_dir

  setup :isolate_library_root

  test "reports missing files, missing mix-out markers and missing BPM" do
    {:ok, set} = Sets.create("Viagem")
    root = Library.library_root()
    File.mkdir_p!(Path.join(root, "F"))

    ok_track =
      insert(:track,
        status: :present,
        rel_path: "F/ok.mp3",
        tag_title: "Redonda",
        bpm_detected: 120.0,
        cue_points: [%{"ms" => 150_000, "type" => "outro", "source" => "auto"}]
      )

    File.write!(Path.join(root, "F/ok.mp3"), "x")

    _broken =
      insert(:track,
        status: :present,
        rel_path: "F/sumida.mp3",
        tag_title: "Sumida",
        bpm_detected: nil,
        cue_points: []
      )

    last = insert(:track, status: :present, rel_path: "F/final.mp3", bpm_detected: 100.0)
    File.write!(Path.join(root, "F/final.mp3"), "x")

    broken = Tracks.get_by_path("F/sumida.mp3")
    for t <- [ok_track, broken, last], do: {:ok, _} = Sets.append(set, t)

    report = Sets.preflight(set)

    assert report.total == 3
    # only the broken middle track shows up; the LAST entry needs no outro
    assert [%{position: 2, title: "Sumida", problems: problems}] = report.issues
    assert :arquivo_sumido in problems
    assert :sem_saida in problems
    assert :sem_bpm in problems
  end

  test "a track without an outro is FINE when its exit boundary is a respiro" do
    {:ok, set} = Sets.create("Baile")
    root = Library.library_root()
    File.mkdir_p!(Path.join(root, "F"))

    no_outro =
      insert(:track,
        status: :present,
        rel_path: "F/semfim.mp3",
        tag_title: "Sem Saída",
        bpm_detected: 100.0,
        duration_ms: 180_000,
        cue_points: []
      )

    File.write!(Path.join(root, "F/semfim.mp3"), "x")
    next = insert(:track, status: :present, rel_path: "F/prox.mp3", bpm_detected: 100.0)
    File.write!(Path.join(root, "F/prox.mp3"), "x")

    {:ok, _} = Sets.append(set, no_outro)
    {:ok, _} = Sets.append(set, next)

    # sem respiro: falta de outro é problema
    {:ok, _} = Sets.connect(set, next, %{"type" => "cut"})
    assert [%{problems: [:sem_saida]}] = Sets.preflight(set).issues

    # com respiro na saída: a faixa toca até o fim de verdade — outro é irrelevante
    {:ok, _} = Sets.set_breather(set, next, true)
    assert Sets.preflight(set).issues == []
  end

  test "a clean set reports zero issues" do
    {:ok, set} = Sets.create("Limpa")
    root = Library.library_root()
    File.mkdir_p!(Path.join(root, "F"))

    for name <- ["a", "b"] do
      track =
        insert(:track,
          status: :present,
          rel_path: "F/#{name}.mp3",
          bpm_detected: 120.0,
          cue_points: [%{"ms" => 150_000, "type" => "outro", "source" => "auto"}]
        )

      File.write!(Path.join(root, "F/#{name}.mp3"), "x")
      {:ok, _} = Sets.append(set, track)
    end

    assert %{total: 2, issues: []} = Sets.preflight(set)
  end
end
