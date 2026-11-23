defmodule Beatgrid.Spotify.Playlist do
  @moduledoc "Read-only catalogue of the tracks exposed by a public Spotify playlist."
  alias Beatgrid.Library
  alias Beatgrid.Library.{Normalize, Tracks}

  @type tracks :: %{title: String.t(), tracks: [%{title: String.t(), artist: String.t()}]}
  @callback fetch(String.t()) :: {:ok, tracks()} | {:error, Beatgrid.Error.t()}

  @adapter Application.compile_env!(:beatgrid, [__MODULE__, :adapter])

  @spec id(String.t()) :: {:ok, String.t()} | :invalid
  def id(input) do
    case URI.parse(input) do
      %URI{scheme: "https", host: "open.spotify.com", path: path} when is_binary(path) ->
        case Regex.run(~r|\A/(?:intl-[a-zA-Z-]+/)?playlist/([A-Za-z0-9]{22})/?\z|, path) do
          [_, id] -> {:ok, id}
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  @spec preview(String.t()) :: {:ok, map()} | {:error, Beatgrid.Error.t()}
  def preview(id) do
    with {:ok, catalog} <- @adapter.fetch(id) do
      titles = Enum.map(catalog.tracks, &Normalize.normalize(&1.title))

      matches =
        titles
        |> Tracks.present_title_matches()
        |> Enum.filter(&File.regular?(Path.join(Library.library_root(), &1.rel_path)))
        |> Map.new(&{{&1.norm_artist, &1.norm_title}, &1.id})

      tracks =
        Enum.map(catalog.tracks, fn track ->
          signature = {Normalize.normalize(track.artist), Normalize.normalize(track.title)}

          Map.put(track, :library_id, matches[signature])
        end)

      {:ok, %{catalog | tracks: tracks}}
    end
  end
end
