defmodule Beatgrid.YouTube.PlaylistsTest do
  use Beatgrid.DataCase, async: true

  import Beatgrid.Factory

  alias Beatgrid.Sets
  alias Beatgrid.YouTube.Playlists

  # A YouTube-imported track with the given raw_tags provenance.
  defp yt(attrs, raw), do: insert(:track, Keyword.put(attrs, :raw_tags, raw))

  describe "group/1" do
    test "groups tracks by playlist url; loose videos become singles" do
      p = "https://youtube.com/playlist?list=ABC"

      a =
        yt([tag_title: "A"], %{
          "youtube_playlist_url" => p,
          "youtube_playlist_index" => 1,
          "youtube_playlist_title" => "Meu Rolê"
        })

      b = yt([tag_title: "B"], %{"youtube_playlist_url" => p, "youtube_playlist_index" => 2})
      solo = yt([tag_title: "Solo"], %{"youtube_url" => "https://youtu.be/x"})

      %{playlists: [pl], singles: singles} = Playlists.group([a, b, solo])

      assert pl.url == p
      assert pl.title == "Meu Rolê"
      assert pl.count == 2
      assert Enum.map(pl.tracks, & &1.id) == [a.id, b.id]
      assert Enum.map(singles, & &1.id) == [solo.id]
    end

    test "orders a playlist by youtube_playlist_index regardless of input order" do
      p = "https://youtube.com/playlist?list=ORD"
      third = yt([tag_title: "3"], %{"youtube_playlist_url" => p, "youtube_playlist_index" => 3})
      first = yt([tag_title: "1"], %{"youtube_playlist_url" => p, "youtube_playlist_index" => 1})
      second = yt([tag_title: "2"], %{"youtube_playlist_url" => p, "youtube_playlist_index" => 2})

      %{playlists: [pl]} = Playlists.group([third, first, second])
      assert Enum.map(pl.tracks, & &1.tag_title) == ~w(1 2 3)
    end

    test "falls back to inserted_at order when any index is missing" do
      p = "https://youtube.com/playlist?list=NOIDX"

      late =
        yt([tag_title: "late", inserted_at: ~U[2026-01-01 11:00:00Z]], %{
          "youtube_playlist_url" => p
        })

      early =
        yt([tag_title: "early", inserted_at: ~U[2026-01-01 10:00:00Z]], %{
          "youtube_playlist_url" => p
        })

      %{playlists: [pl]} = Playlists.group([late, early])
      assert Enum.map(pl.tracks, & &1.tag_title) == ~w(early late)
    end

    test "title falls back to a friendly name when none was captured" do
      p = "https://youtube.com/playlist?list=NOTITLE"
      a = yt([tag_title: "A"], %{"youtube_playlist_url" => p, "youtube_playlist_index" => 1})

      %{playlists: [pl]} = Playlists.group([a])
      assert pl.title == "Playlist do YouTube"
    end

    test "empty input yields no playlists and no singles" do
      assert %{playlists: [], singles: []} = Playlists.group([])
    end

    test "a track with empty raw_tags is a single, not a crash" do
      solo = insert(:track, tag_title: "Bare", raw_tags: %{})
      assert %{playlists: [], singles: [%{id: id}]} = Playlists.group([solo])
      assert id == solo.id
    end
  end

  describe "create_set/1" do
    test "builds a named set with the tracks in order and auto-connected transitions" do
      p = "https://youtube.com/playlist?list=SET"

      tracks =
        for i <- 1..3 do
          yt([tag_title: "T#{i}"], %{
            "youtube_playlist_url" => p,
            "youtube_playlist_index" => i,
            "youtube_playlist_title" => "Festa"
          })
        end

      %{playlists: [pl]} = Playlists.group(tracks)

      {:ok, set} = Playlists.create_set(pl)
      assert set.name == "Festa"

      entries = Sets.entries(set)
      assert Enum.map(entries, & &1.track.tag_title) == ~w(T1 T2 T3)
      assert Enum.map(entries, & &1.position) == [1, 2, 3]

      # connect_all wires every consecutive pair — the opener has no incoming.
      assert Enum.at(entries, 0).transition == nil
      assert Enum.at(entries, 1).transition["enabled"] == true
      assert Enum.at(entries, 2).transition["enabled"] == true
    end
  end
end
