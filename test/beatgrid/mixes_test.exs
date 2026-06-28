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

  describe "import_url/1" do
    test "creates a downloading mix and enqueues a MixDownloadWorker" do
      assert {:ok, mix} = Beatgrid.Mixes.import_url("https://soundcloud.com/dj/set")
      assert mix.status == :downloading
      assert mix.source == "soundcloud"
      assert_enqueued(worker: Beatgrid.Workers.MixDownloadWorker, args: %{mix_id: mix.id})
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
end
