defmodule Beatgrid.Library.ScannerTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Audio.Metadata
  alias Beatgrid.Library.{Scanner, Tracks}

  defp healthy(title, artist) do
    {:ok, %Metadata{title: title, artist: artist, bitrate_kbps: 320, duration_ms: 200_000}}
  end

  @tag :tmp_dir
  test "a rescan preserves reviewed names and playlist provenance", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "_Inbox"))
    File.write!(Path.join(root, "_Inbox/song.mp3"), "audio")

    insert(:track,
      rel_path: "_Inbox/song.mp3",
      filename: "song.mp3",
      source_playlist: "youtube",
      tag_artist: "Mestre Zinho",
      tag_title: "Queijinho do amor",
      raw_tags: %{"youtube_playlist_index" => 2, "youtube_url" => "https://youtu.be/ZvODpklNB2c"}
    )

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ -> healthy(nil, nil) end)
    assert {:ok, %{scanned: 1}} = Scanner.scan(root)
    track = Tracks.get_by_path("_Inbox/song.mp3")
    assert track.source_playlist == "youtube"
    assert track.tag_artist == "Mestre Zinho"
    assert track.tag_title == "Queijinho do amor"
    assert track.raw_tags["youtube_playlist_index"] == 2
  end

  @tag :tmp_dir
  test "a rescan keeps manual edits and source playlist while refreshing unedited tags", %{
    tmp_dir: root
  } do
    rel = "_Inbox/song.mp3"
    File.mkdir_p!(Path.join(root, "_Inbox"))
    File.write!(Path.join(root, rel), "audio")

    track =
      insert(:track,
        rel_path: rel,
        source_playlist: "Sexta no salão",
        manual_fields: ["artist", "year"],
        tag_artist: "Crédito revisado",
        tag_year: 1974
      )

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ -> healthy("Novo título", "Outro crédito") end)
    assert {:ok, %{scanned: 1}} = Scanner.scan(root)
    updated = Tracks.get(track.id)
    assert updated.tag_artist == "Crédito revisado"
    assert updated.tag_year == 1974
    assert updated.source_playlist == "Sexta no salão"
    assert updated.tag_title == "Novo título"
  end

  @tag :tmp_dir
  test "rescanning a mix cut keeps the original set link, range and reviewed credit", %{
    tmp_dir: root
  } do
    rel = "cut.mp3"
    File.write!(Path.join(root, rel), "audio")
    origin = %{"recorte_mix_id" => Uniq.UUID.uuid7(), "recorte_start_ms" => 8000}

    track =
      insert(:track,
        rel_path: rel,
        source_playlist: "recorte",
        raw_tags: Map.put(origin, "encoder", "old"),
        tag_title: "Faixa do baile"
      )

    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ ->
      {:ok, %Metadata{raw_tags: %{"encoder" => "new"}}}
    end)

    assert {:ok, %{scanned: 1}} = Scanner.scan(root)
    updated = Tracks.get(track.id)
    assert updated.raw_tags == Map.put(origin, "encoder", "new")
    assert updated.source_playlist == "recorte"
    assert updated.tag_title == "Faixa do baile"
  end

  @tag :tmp_dir
  test "scans audio files and persists tracks with metadata + quality flags", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/good.mp3"), "fake-good")
    File.write!(Path.join(root, "MPB/bad.mp3"), "fake-bad")
    File.write!(Path.join(root, "MPB/notes.txt"), "ignore me")

    insert(:genre_folder, dir_name: "MPB", key: "mpb")

    stub(Beatgrid.Audio.Mock, :read_metadata, fn path ->
      if String.ends_with?(path, "good.mp3"),
        do: healthy("Good Song", "Some Artist"),
        else: {:error, :not_audio}
    end)

    assert {:ok, %{scanned: 2}} = Scanner.scan(root)

    good = Tracks.get_by_path("MPB/good.mp3")
    assert good.tag_title == "Good Song"
    assert good.norm_title == "good song"
    assert good.format == :mp3
    assert good.genre_folder == "mpb"
    assert good.source_playlist == "MPB"
    assert good.content_sha256 != nil
    assert good.quality_issues == []
    assert good.status == :present

    bad = Tracks.get_by_path("MPB/bad.mp3")
    assert bad.quality_issues == [:not_audio]

    # non-audio extensions are skipped entirely
    assert Tracks.get_by_path("MPB/notes.txt") == nil
  end

  @tag :tmp_dir
  test "backups and cached mixes stay out of the catalogue on rescan", %{tmp_dir: root} do
    backup = "_Backups/Gain/batch/_Inbox/song.mp3"
    mix = "_Mixes/full-set.mp3"
    quarantine = "_Quarantine/song.mp3"
    nested = "MPB/_Backups/demo.mp3"

    for rel <- [backup, mix, quarantine, nested] do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "audio")
    end

    legacy = insert(:track, rel_path: backup, status: :present)
    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ -> healthy("Song", "DJ") end)

    assert {:ok, %{scanned: 2}} = Scanner.scan(root, mark_missing: true)
    assert Tracks.get(legacy.id).status == :missing
    assert Tracks.get_by_path(mix) == nil
    assert Tracks.get_by_path(quarantine).status == :quarantined
    assert Tracks.get_by_path(nested).status == :present
    assert File.read!(Path.join(root, backup)) == "audio"
  end

  @tag :tmp_dir
  test "marks tracks whose files disappeared as missing (when asked)", %{tmp_dir: root} do
    path = Path.join(root, "x.mp3")
    File.write!(path, "data")
    stub(Beatgrid.Audio.Mock, :read_metadata, fn _ -> healthy("X", "Y") end)

    {:ok, _} = Scanner.scan(root, mark_missing: true)
    assert Tracks.get_by_path("x.mp3").status == :present

    File.rm!(path)
    {:ok, _} = Scanner.scan(root, mark_missing: true)
    assert Tracks.get_by_path("x.mp3").status == :missing
  end
end
