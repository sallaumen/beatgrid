defmodule Beatgrid.Library.TracksTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.Tracks

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{rel_path: "MPB/song.mp3", filename: "song.mp3", format: :mp3},
      overrides
    )
  end

  describe "upsert_by_path/1" do
    test "inserts a track and derives normalized artist/title" do
      assert {:ok, t} =
               Tracks.upsert_by_path(
                 attrs(%{tag_title: "Construção", tag_artist: "Chico Buarque"})
               )

      assert t.norm_title == "construcao"
      assert t.norm_artist == "chico buarque"
      assert t.status == :present
      assert t.quality_issues == []
    end

    test "updates the existing track with the same rel_path (idempotent re-scan)" do
      {:ok, _} = Tracks.upsert_by_path(attrs(%{bitrate_kbps: 128}))
      {:ok, t} = Tracks.upsert_by_path(attrs(%{bitrate_kbps: 320}))

      assert t.bitrate_kbps == 320
      assert Tracks.count() == 1
    end

    test "requires rel_path and filename" do
      assert {:error, changeset} = Tracks.upsert_by_path(%{format: :mp3})
      errors = errors_on(changeset)
      assert errors.rel_path != []
      assert errors.filename != []
    end

    test "rejects an out-of-range rating" do
      assert {:error, changeset} = Tracks.upsert_by_path(attrs(%{rating: 99}))
      assert errors_on(changeset).rating != []
    end

    test "stores quality issues as a list" do
      assert {:ok, t} =
               Tracks.upsert_by_path(attrs(%{quality_issues: [:missing_tags, :low_bitrate]}))

      assert t.quality_issues == [:missing_tags, :low_bitrate]
    end
  end

  describe "get_by_path/1" do
    test "fetches by relative path or returns nil" do
      {:ok, _} = Tracks.upsert_by_path(attrs())
      assert %{rel_path: "MPB/song.mp3"} = Tracks.get_by_path("MPB/song.mp3")
      assert Tracks.get_by_path("nope.mp3") == nil
    end
  end

  describe "all_tags/0" do
    test "returns distinct, sorted, non-blank tags across the library" do
      {:ok, _} =
        Tracks.upsert_by_path(
          attrs(%{rel_path: "a.mp3", filename: "a.mp3", tags: ["forró", "abertura"]})
        )

      {:ok, _} =
        Tracks.upsert_by_path(
          attrs(%{rel_path: "b.mp3", filename: "b.mp3", tags: ["forró", "fechamento", ""]})
        )

      {:ok, _} = Tracks.upsert_by_path(attrs(%{rel_path: "c.mp3", filename: "c.mp3", tags: []}))

      assert Tracks.all_tags() == ["abertura", "fechamento", "forró"]
    end

    test "returns an empty list when no track has tags" do
      {:ok, _} = Tracks.upsert_by_path(attrs())
      assert Tracks.all_tags() == []
    end
  end

  describe "versions_of/1" do
    test "links different versions of the same song, excluding exact dups + other songs" do
      studio =
        insert(:track,
          status: :present,
          tag_artist: "Gonzaga",
          tag_title: "Asa Branca",
          norm_artist: "gonzaga",
          norm_title: "asa branca",
          content_sha256: "aaa"
        )

      live =
        insert(:track,
          status: :present,
          tag_artist: "Gonzaga",
          tag_title: "Asa Branca (Ao Vivo)",
          norm_artist: "gonzaga",
          norm_title: "asa branca ao vivo",
          content_sha256: "bbb"
        )

      # exact-content dup of the studio (same hash) → belongs in dedup, not versions
      insert(:track,
        status: :present,
        tag_artist: "Gonzaga",
        tag_title: "Asa Branca",
        norm_artist: "gonzaga",
        norm_title: "asa branca",
        content_sha256: "aaa"
      )

      other =
        insert(:track,
          status: :present,
          tag_artist: "Gonzaga",
          tag_title: "Qui Nem Jiló",
          norm_artist: "gonzaga",
          norm_title: "qui nem jilo"
        )

      ids = studio |> Tracks.versions_of() |> Enum.map(& &1.id)

      assert live.id in ids
      refute studio.id in ids
      refute other.id in ids
      # the exact dup (same hash + same norm_title) is not a "version"
      assert length(ids) == 1
    end

    test "links versions even when the title lives only in the filename (tag_title nil)" do
      studio =
        insert(:track,
          status: :present,
          tag_artist: "Gonzaga",
          tag_title: nil,
          norm_artist: "gonzaga",
          filename: "Gonzaga - Asa Branca.mp3",
          content_sha256: "a"
        )

      live =
        insert(:track,
          status: :present,
          tag_artist: "Gonzaga",
          tag_title: nil,
          norm_artist: "gonzaga",
          filename: "Gonzaga - Asa Branca (Ao Vivo).mp3",
          content_sha256: "b"
        )

      assert [%{id: id}] = Tracks.versions_of(studio)
      assert id == live.id
    end

    test "returns nothing for a track with no artist (avoids the blank-artist bucket)" do
      a = insert(:track, status: :present, tag_artist: nil, norm_artist: "", tag_title: "X")
      insert(:track, status: :present, tag_artist: nil, norm_artist: "", tag_title: "Y")

      assert Tracks.versions_of(a) == []
    end
  end

  describe "markers" do
    test "add_marker appends a cue point (sorted by position); remove_marker drops it" do
      {:ok, track} = Tracks.upsert_by_path(attrs())

      {:ok, t1} = Tracks.add_marker(track, 90_000, "refrão")
      {:ok, t2} = Tracks.add_marker(t1, 20_000)

      assert Enum.map(t2.cue_points, & &1["ms"]) == [20_000, 90_000]
      assert Enum.find(t2.cue_points, &(&1["ms"] == 90_000))["label"] == "refrão"

      {:ok, t3} = Tracks.remove_marker(t2, 20_000)
      assert Enum.map(t3.cue_points, & &1["ms"]) == [90_000]
    end
  end
end
