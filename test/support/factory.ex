defmodule Beatgrid.Factory do
  @moduledoc """
  ExMachina factories. Keep defaults minimal — every default cascades into other
  tests. Use the `Map.pop_lazy` optional-association idiom when adding associations.
  """
  use ExMachina.Ecto, repo: Beatgrid.Repo

  alias Beatgrid.Library.{GenreFolder, Track}
  alias Beatgrid.Soundcharts.Song

  def genre_folder_factory do
    %GenreFolder{
      key: sequence(:genre_folder_key, &"genre-#{&1}"),
      display_name: sequence(:genre_folder_name, &"Genre #{&1}"),
      dir_name: sequence(:genre_folder_dir, &"Genre #{&1}"),
      sort_order: sequence(:genre_folder_sort, & &1)
    }
  end

  def track_factory do
    %Track{
      rel_path: sequence(:track_rel_path, &"_Inbox/track-#{&1}.mp3"),
      filename: sequence(:track_filename, &"track-#{&1}.mp3"),
      format: :mp3,
      status: :present,
      quality_issues: []
    }
  end

  def soundcharts_song_factory do
    %Song{
      sc_uuid: sequence(:sc_uuid, &"sc-uuid-#{&1}"),
      name: sequence(:sc_name, &"Song #{&1}"),
      credit_name: "Some Artist"
    }
  end

  def recommendation_factory do
    %Beatgrid.Repertoire.Recommendation{
      artist: sequence(:rec_artist, &"Artist #{&1}"),
      song: sequence(:rec_song, &"Song #{&1}"),
      reason: "fits the style",
      youtube_query: "artist song",
      source: :gaps,
      genre_folder: "mpb",
      status: :new
    }
  end

  def mix_factory do
    %Beatgrid.Mixes.Mix{
      source: "soundcloud",
      source_url: sequence(:mix_url, &"https://soundcloud.com/dj/set-#{&1}"),
      title: "Live @ Somewhere",
      dj: "DJ Test",
      duration_ms: 3_600_000,
      description: "",
      status: :ready
    }
  end

  def mix_segment_factory do
    %Beatgrid.Mixes.Segment{
      mix: build(:mix),
      position: 0,
      start_ms: 0,
      name_source: :description
    }
  end
end
