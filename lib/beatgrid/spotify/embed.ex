defmodule Beatgrid.Spotify.Embed do
  @moduledoc "Reads the public playlist embed. Its visible track list may be a subset."
  @behaviour Beatgrid.Spotify.Playlist
  alias Beatgrid.Error

  @impl true
  def fetch(id, options \\ []) do
    options = Keyword.merge([retry: false, receive_timeout: 10_000], options)
    url = "https://open.spotify.com/embed/playlist/" <> URI.encode_www_form(id)

    with {:ok, %{status: 200, body: html}} when is_binary(html) <- Req.get(url, options),
         [_, json] <- Regex.run(~r{<script\b[^>]*\bid="__NEXT_DATA__"[^>]*>(.*?)</script>}s, html),
         {:ok, state} <- Jason.decode(json),
         %{"title" => title, "trackList" => entries} when is_list(entries) <-
           get_in(state, ~w(props pageProps state data entity)) do
      tracks =
        for %{"title" => title, "subtitle" => artist} <- entries,
            is_binary(title) and is_binary(artist),
            do: %{title: title, artist: artist}

      {:ok, %{title: title, tracks: tracks}}
    else
      _ ->
        {:error,
         Error.new(
           :spotify_unavailable,
           "Não foi possível ler a playlist. Confira se ela está pública e tente novamente."
         )}
    end
  end
end
