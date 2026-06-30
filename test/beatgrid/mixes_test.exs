defmodule Beatgrid.MixesTest do
  use Beatgrid.DataCase, async: true, oban: true

  import Beatgrid.Factory

  alias Beatgrid.Library.Normalize
  alias Beatgrid.Mixes

  test "create_mix/1 requires source_url" do
    assert {:error, cs} = Mixes.create_mix(%{source: "soundcloud"})
    assert %{source_url: ["can't be blank"]} = errors_on(cs)
  end

  test "get_with_segments/1 preloads segments ordered by position" do
    mix = insert(:mix)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 60_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)

    loaded = Mixes.get_with_segments(mix.id)
    assert Enum.map(loaded.segments, & &1.position) == [0, 1]
  end

  test "list_mixes/0 returns mixes newest first" do
    old = insert(:mix, inserted_at: ~U[2026-01-01 00:00:00Z])
    new = insert(:mix, inserted_at: ~U[2026-02-01 00:00:00Z])
    assert Enum.map(Mixes.list_mixes(), & &1.id) == [new.id, old.id]
  end

  test "update_segment/2 edits the name" do
    mix = insert(:mix)
    seg = insert(:mix_segment, mix: mix, artist: nil, title: nil)

    assert {:ok, seg} =
             Mixes.update_segment(seg, %{artist: "Djavan", title: "Sina", name_source: :manual})

    assert seg.artist == "Djavan" and seg.name_source == :manual
  end

  describe "detect_source/1" do
    test "youtube hosts" do
      for u <- [
            "https://www.youtube.com/watch?v=a93fldI5DSU",
            "https://youtu.be/a93fldI5DSU",
            "https://m.youtube.com/watch?v=x"
          ] do
        assert Mixes.detect_source(u) == {:ok, "youtube"}
      end
    end

    test "soundcloud hosts" do
      assert Mixes.detect_source("https://soundcloud.com/dj/set") == {:ok, "soundcloud"}
      assert Mixes.detect_source("https://on.soundcloud.com/abc") == {:ok, "soundcloud"}
    end

    test "unsupported host" do
      assert Mixes.detect_source("https://vimeo.com/123") == {:error, :unsupported_source}
      assert Mixes.detect_source("not a url") == {:error, :unsupported_source}
    end
  end

  describe "import_url/1" do
    test "creates a downloading mix and enqueues a MixDownloadWorker" do
      assert {:ok, mix} = Beatgrid.Mixes.import_url("https://soundcloud.com/dj/set")
      assert mix.status == :downloading
      assert mix.source == "soundcloud"
      assert_enqueued(worker: Beatgrid.Workers.MixDownloadWorker, args: %{mix_id: mix.id})
    end

    test "import_url/1 sets source youtube for a youtube url" do
      assert {:ok, mix} = Mixes.import_url("https://youtu.be/a93fldI5DSU")
      assert mix.source == "youtube"
      assert mix.status == :downloading
      assert_enqueued(worker: Beatgrid.Workers.MixDownloadWorker, args: %{mix_id: mix.id})
    end

    test "import_url/1 rejects unsupported source" do
      assert Mixes.import_url("https://vimeo.com/123") == {:error, :unsupported_source}
    end
  end

  describe "match_track/2" do
    test "matches a present track by normalized artist + title (high)" do
      track =
        insert(:track,
          status: :present,
          tag_artist: "Djavan",
          tag_title: "Sina",
          norm_artist: Normalize.normalize("Djavan"),
          norm_title: Normalize.normalize("Sina")
        )

      assert %{track_id: id, confidence: :high} = Mixes.match_track("Djavan", "Sina")
      assert id == track.id
    end

    test "returns nil when nothing matches or the name is blank" do
      assert Mixes.match_track("Ninguém", "Nada") == nil
      assert Mixes.match_track(nil, "Sina") == nil
      assert Mixes.match_track("Djavan", "") == nil
    end
  end

  test "changeset casts chapters and chapters_role" do
    attrs = %{
      source: "youtube",
      source_url: "https://youtu.be/cap",
      chapters: [%{"start_ms" => 0, "title" => "Intro"}],
      chapters_role: :djs
    }

    assert {:ok, mix} = Mixes.create_mix(attrs)
    assert mix.chapters == [%{"start_ms" => 0, "title" => "Intro"}]
    assert mix.chapters_role == :djs
  end

  describe "analyze_all/1" do
    test "analyze_all enqueues MixAnalyzeWorker with free_djs" do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")
      assert {:ok, _} = Mixes.analyze_all(mix)

      assert_enqueued(
        worker: Beatgrid.Workers.MixAnalyzeWorker,
        args: %{mix_id: mix.id, free_djs: true}
      )
    end

    test "analyze_all without audio -> :no_audio" do
      mix =
        insert(:mix, status: :ready, audio_path: nil, audio_deleted_at: ~U[2026-06-29 00:00:00Z])

      assert Mixes.analyze_all(mix) == {:error, :no_audio}
    end
  end

  describe "recognize_unnamed/2" do
    # AudD is configured by default in tests (config/test.exs); don't mutate that global
    # here — this module is async and would race the gate tests in other modules.
    test "default enqueues a batch recognize (skips already-tried)" do
      mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")
      assert {:ok, _} = Mixes.recognize_unnamed(mix)
      assert_enqueued(worker: Beatgrid.Workers.MixRecognizeWorker, args: %{mix_id: mix.id})

      refute_enqueued(
        worker: Beatgrid.Workers.MixRecognizeWorker,
        args: %{mix_id: mix.id, retry_all: true}
      )
    end

    test "retry_all enqueues with the retry_all flag" do
      mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")
      assert {:ok, _} = Mixes.recognize_unnamed(mix, true)

      assert_enqueued(
        worker: Beatgrid.Workers.MixRecognizeWorker,
        args: %{mix_id: mix.id, retry_all: true}
      )
    end
  end

  describe "redownload_audio/1" do
    test "marks the mix downloading and enqueues a restore-only download" do
      mix =
        insert(:mix,
          status: :ready,
          audio_path: nil,
          audio_deleted_at: ~U[2026-06-30 00:00:00Z]
        )

      assert {:ok, updated} = Mixes.redownload_audio(mix)
      assert updated.status == :downloading

      assert_enqueued(
        worker: Beatgrid.Workers.MixDownloadWorker,
        args: %{mix_id: mix.id, restore_only: true}
      )
    end
  end

  describe "rename_dj_part/2 and delete_dj_part/1" do
    test "rename_dj_part updates the name" do
      mix = insert(:mix)
      part = insert(:dj_part, mix: mix, dj_name: "DJ VHSFNTG", source: :image)
      assert {:ok, p} = Mixes.rename_dj_part(part.id, "DJ VHANNY")
      assert p.dj_name == "DJ VHANNY"
    end

    test "rename_dj_part blank -> nil (Sem DJ)" do
      mix = insert(:mix)
      part = insert(:dj_part, mix: mix, dj_name: "X", source: :image)
      assert {:ok, p} = Mixes.rename_dj_part(part.id, "   ")
      assert p.dj_name == nil
    end

    test "delete_dj_part removes it" do
      mix = insert(:mix)
      part = insert(:dj_part, mix: mix, source: :image)
      assert {:ok, _} = Mixes.delete_dj_part(part.id)
      assert Mixes.get_with_dj_parts(mix.id).dj_parts == []
    end
  end

  describe "dj parts" do
    test "set_dj_parts_manual builds contiguous parts snapped to segment starts" do
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      insert(:mix_segment, mix: mix, position: 1, start_ms: 305_000)

      assert {:ok, 2} = Mixes.set_dj_parts_manual(mix, "0:00 A\n5:00 B")
      parts = Mixes.get_with_dj_parts(mix.id).dj_parts
      assert Enum.map(parts, & &1.dj_name) == ["A", "B"]
      # 5:00 = 300_000 snaps to the nearest segment start (305_000)
      assert Enum.map(parts, & &1.start_ms) == [0, 305_000]
      assert Enum.map(parts, & &1.end_ms) == [305_000, 600_000]
      assert Enum.all?(parts, &(&1.source == :manual))
    end

    test "automatic source is blocked when manual parts exist" do
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      {:ok, _} = Mixes.set_dj_parts_manual(mix, "0:00 A")

      assert Mixes.replace_dj_parts(mix, :audio, [%{start_ms: 0, dj_name: nil}]) ==
               {:error, :manual_present}
    end

    test "group_by_dj groups segments by containment, leftovers under nil" do
      mix = insert(:mix, duration_ms: 600_000)
      s0 = insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      s1 = insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)
      part = insert(:dj_part, mix: mix, start_ms: 0, end_ms: 250_000, dj_name: "A")

      assert [{p, [g0]}, {nil, [g1]}] = Mixes.group_by_dj([s0, s1], [part])
      assert p.dj_name == "A" and g0.id == s0.id and g1.id == s1.id
    end

    test "clear_dj_parts removes them" do
      mix = insert(:mix)
      insert(:dj_part, mix: mix)
      assert {1, nil} = Mixes.clear_dj_parts(mix)
      assert Mixes.get_with_dj_parts(mix.id).dj_parts == []
    end

    test "set_dj_parts_from_chapters creates :chapter parts, flips role to :djs, re-analyzes" do
      mix =
        insert(:mix,
          duration_ms: 600_000,
          chapters: [
            %{"start_ms" => 0, "title" => "DJ A"},
            %{"start_ms" => 300_000, "title" => "DJ B"}
          ],
          chapters_role: :tracks
        )

      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

      assert {:ok, 2} = Mixes.set_dj_parts_from_chapters(mix)
      reloaded = Mixes.get_with_dj_parts(mix.id)
      assert Enum.map(reloaded.dj_parts, & &1.dj_name) == ["DJ A", "DJ B"]
      assert Enum.all?(reloaded.dj_parts, &(&1.source == :chapter))
      assert reloaded.chapters_role == :djs
      assert_enqueued(worker: Beatgrid.Workers.MixAnalyzeWorker, args: %{mix_id: mix.id})
    end

    test "set_dj_parts_from_chapters with no chapters -> error" do
      mix = insert(:mix, chapters: [])
      assert Mixes.set_dj_parts_from_chapters(mix) == {:error, :no_chapters}
    end

    test "snap-collision: a nil-name part and a named part at the same boundary keep the named one" do
      # The :audio/:image source can pass dj_name: nil for boundary markers. If another
      # part snaps to the same start_ms, Enum.dedup_by (pre-fix) keeps the first-sorted
      # entry — which may be the nil one. The fix uses group_by + Enum.find to keep the
      # named entry when available.
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

      # Call replace_dj_parts directly with a nil-named part at 0 and a named part also
      # at 0 — simulating the :audio source producing a collision at the same segment.
      # After fix: the named entry "DJ A" must survive.
      parts = [%{start_ms: 0, dj_name: nil}, %{start_ms: 0, dj_name: "DJ A"}]
      assert {:ok, _} = Mixes.replace_dj_parts(mix, :audio, parts)
      persisted = Mixes.get_with_dj_parts(mix.id).dj_parts
      part_at_zero = Enum.find(persisted, &(&1.start_ms == 0))
      assert part_at_zero != nil
      assert part_at_zero.dj_name == "DJ A"
    end

    test "replace_dj_parts with coverage_until_ms emits a nil tail instead of stretching the last DJ" do
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

      {:ok, _} =
        Mixes.replace_dj_parts(mix, :image, [%{start_ms: 0, dj_name: "DJ A"}],
          coverage_until_ms: 300_000
        )

      parts = Mixes.get_with_dj_parts(mix.id).dj_parts |> Enum.sort_by(& &1.start_ms)
      named = Enum.filter(parts, & &1.dj_name)
      assert List.last(named).dj_name == "DJ A"
      assert List.last(named).end_ms == 300_000

      assert Enum.any?(
               parts,
               &(&1.dj_name == nil and &1.start_ms == 300_000 and &1.end_ms == 600_000)
             )
    end

    test "replace_dj_parts without coverage stretches the last DJ to full duration (unchanged)" do
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)

      {:ok, _} = Mixes.replace_dj_parts(mix, :image, [%{start_ms: 0, dj_name: "DJ A"}])
      [part] = Mixes.get_with_dj_parts(mix.id).dj_parts
      assert part.dj_name == "DJ A" and part.end_ms == 600_000
    end

    test "coverage tail survives even when no segment exists after the last DJ" do
      mix = insert(:mix, duration_ms: 600_000)
      # only ONE segment, at 0 — the coverage boundary would snap BACKWARD onto DJ A's
      # start under naive nearest-snap and be dropped by the dedup; it must not be.
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)

      {:ok, _} =
        Mixes.replace_dj_parts(mix, :image, [%{start_ms: 0, dj_name: "DJ A"}],
          coverage_until_ms: 120_000
        )

      parts = Mixes.get_with_dj_parts(mix.id).dj_parts |> Enum.sort_by(& &1.start_ms)
      named = Enum.filter(parts, & &1.dj_name)
      assert List.last(named).end_ms == 120_000

      assert Enum.any?(
               parts,
               &(&1.dj_name == nil and &1.start_ms == 120_000 and &1.end_ms == 600_000)
             )
    end

    test "overlapping parts that snap to the same segment collapse to distinct boundaries" do
      mix = insert(:mix, duration_ms: 600_000)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

      # Both parts snap to the nearest segment start (0) and collapse into one;
      # the named entry survives. (The collapse is also logged at :info in dev/prod.)
      parts = [%{start_ms: 0, dj_name: "DJ A"}, %{start_ms: 1_000, dj_name: "DJ B"}]
      {:ok, count} = Mixes.replace_dj_parts(mix, :image, parts)

      persisted = Mixes.get_with_dj_parts(mix.id).dj_parts
      assert count == 1
      assert Enum.map(persisted, & &1.start_ms) == [0]
      assert Enum.map(persisted, & &1.dj_name) == ["DJ A"]
    end
  end
end
