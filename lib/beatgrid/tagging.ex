defmodule Beatgrid.Tagging do
  @moduledoc """
  Writes the genre folder's display name into a track's ID3 genre tag (through the
  `Tagging.Writer` port) and mirrors it onto `track.tag_genre`. Called when a
  classification is applied so Serato and Finder show the curated genre. The real
  adapter is `Beatgrid.Tagging.Ffmpeg`; tests use `Beatgrid.Tagging.Mock`.
  """
  alias Beatgrid.Library
  alias Beatgrid.Library.{GenreFolders, Track, Tracks}

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Tagging.Writer, :adapter],
             Beatgrid.Tagging.Ffmpeg
           )

  @doc """
  Writes the track's genre tag from its `genre_folder`. Returns the updated track,
  or an error (`:no_genre_folder`, `{:unknown_genre_folder, key}`, or the writer's
  own error) without changing the row when the write fails.
  """
  @spec write_genre(Track.t()) :: {:ok, Track.t()} | {:error, term()}
  def write_genre(%Track{genre_folder: nil}), do: {:error, :no_genre_folder}

  def write_genre(%Track{genre_folder: key} = track) do
    with %{display_name: genre} <- GenreFolders.get_by_key(key),
         :ok <- @adapter.write_genre(abs_path(track), genre) do
      Tracks.update(track, %{tag_genre: genre})
    else
      nil -> {:error, {:unknown_genre_folder, key}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Writes an explicit genre value back onto a track's file (used to reverse a tag
  operation). A `nil` previous genre clears the tag.
  """
  @spec restore_genre(Track.t(), String.t() | nil) :: {:ok, Track.t()} | {:error, term()}
  def restore_genre(track, genre) do
    with :ok <- @adapter.write_genre(abs_path(track), genre || "") do
      Tracks.update(track, %{tag_genre: genre})
    end
  end

  defp abs_path(track), do: Path.join(Library.library_root(), track.rel_path)
end
