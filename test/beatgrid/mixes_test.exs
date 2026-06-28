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

  test "cancel_cleanup clears the cleanup_job_id" do
    mix = insert(:mix, status: :ready, cleanup_job_id: 999_999)
    assert {:ok, updated} = Beatgrid.Mixes.cancel_cleanup(mix)
    assert updated.cleanup_job_id == nil
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
      assert Mixes.replace_dj_parts(mix, :audio, [%{start_ms: 0, dj_name: nil}]) == {:error, :manual_present}
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
  end
end
