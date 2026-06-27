defmodule Beatgrid.Repertoire.RecommendationTest do
  use Beatgrid.DataCase, async: true
  alias Beatgrid.Repertoire.Recommendation

  test "valid with a folder scope" do
    cs =
      Recommendation.changeset(%Recommendation{}, %{
        artist: "Elis",
        song: "Águas de Março",
        reason: "canon",
        source: :gaps,
        genre_folder: "mpb",
        youtube_query: "Elis Águas de Março"
      })

    assert cs.valid?
  end

  test "requires artist, song, source and at least one scope" do
    refute Recommendation.changeset(%Recommendation{}, %{artist: "x"}).valid?

    refute Recommendation.changeset(%Recommendation{}, %{artist: "a", song: "b", source: :gaps}).valid?
  end

  test "valid with a track scope" do
    track = insert(:track)

    cs =
      Recommendation.changeset(%Recommendation{}, %{
        artist: "a",
        song: "b",
        source: :match,
        track_id: track.id,
        youtube_query: "a b"
      })

    assert cs.valid?
  end
end
