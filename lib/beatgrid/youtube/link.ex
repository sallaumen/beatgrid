defmodule Beatgrid.YouTube.Link do
  @moduledoc "Identifies a video or explicit playlist in a pasted YouTube link."

  @hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com)

  @spec parse(String.t()) :: {:video | :playlist, String.t()} | :invalid
  def parse(input) do
    uri = URI.parse(input)
    params = URI.decode_query(uri.query || "")

    case {uri.scheme, uri.host, String.split(uri.path || "", "/", trim: true)} do
      {scheme, host, path} when scheme in ["http", "https"] and host in @hosts ->
        youtube_path(path, params)

      {scheme, "youtu.be", [id]} when scheme in ["http", "https"] ->
        video(id)

      _ ->
        :invalid
    end
  end

  defp youtube_path(["watch"], %{"v" => id}), do: video(id)
  defp youtube_path([kind, id], _) when kind in ~w(shorts live embed), do: video(id)

  defp youtube_path(["playlist"], %{"list" => id}) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id), do: {:playlist, id}, else: :invalid
  end

  defp youtube_path(_, _), do: :invalid

  @spec video(term()) :: {:video, String.t()} | :invalid
  def video(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id), do: {:video, id}, else: :invalid
  end

  def video(_), do: :invalid

  @spec url({:video | :playlist, String.t()}) :: String.t()
  def url({:video, id}), do: "https://www.youtube.com/watch?v=" <> id
  def url({:playlist, id}), do: "https://www.youtube.com/playlist?list=" <> id
end
