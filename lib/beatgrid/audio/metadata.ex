defmodule Beatgrid.Audio.Metadata do
  @moduledoc """
  Normalized audio metadata parsed from `ffprobe -print_format json` output.
  """

  @type t :: %__MODULE__{
          duration_ms: non_neg_integer() | nil,
          bitrate_kbps: non_neg_integer() | nil,
          sample_rate_hz: non_neg_integer() | nil,
          channels: non_neg_integer() | nil,
          format_name: String.t() | nil,
          title: String.t() | nil,
          artist: String.t() | nil,
          album: String.t() | nil,
          album_artist: String.t() | nil,
          year: integer() | nil,
          track_no: integer() | nil,
          isrc: String.t() | nil,
          genre: String.t() | nil,
          comment: String.t() | nil,
          raw_tags: map()
        }

  defstruct duration_ms: nil,
            bitrate_kbps: nil,
            sample_rate_hz: nil,
            channels: nil,
            format_name: nil,
            title: nil,
            artist: nil,
            album: nil,
            album_artist: nil,
            year: nil,
            track_no: nil,
            isrc: nil,
            genre: nil,
            comment: nil,
            raw_tags: %{}

  @doc """
  Builds a `Metadata` from a parsed `ffprobe` JSON map. Returns
  `{:error, :not_audio}` when the file has no audio stream.
  """
  @spec from_ffprobe(map()) :: {:ok, t()} | {:error, :not_audio}
  def from_ffprobe(%{} = json) do
    streams = Map.get(json, "streams", [])
    format = Map.get(json, "format", %{})

    case Enum.find(streams, &(&1["codec_type"] == "audio")) do
      nil ->
        {:error, :not_audio}

      audio ->
        tags = Map.get(format, "tags", %{})

        {:ok,
         %__MODULE__{
           duration_ms: parse_duration_ms(format["duration"]),
           bitrate_kbps: parse_bitrate_kbps(format["bit_rate"] || audio["bit_rate"]),
           sample_rate_hz: parse_int(audio["sample_rate"]),
           channels: parse_int(audio["channels"]),
           format_name: format["format_name"],
           title: tag(tags, ~w(title)),
           artist: tag(tags, ~w(artist)),
           album: tag(tags, ~w(album)),
           album_artist: tag(tags, ~w(album_artist albumartist)),
           year: parse_year(tag(tags, ~w(date year originalyear))),
           track_no: parse_track_no(tag(tags, ~w(track))),
           isrc: tag(tags, ~w(isrc tsrc)),
           genre: tag(tags, ~w(genre)),
           comment: tag(tags, ~w(comment)),
           raw_tags: tags
         }}
    end
  end

  # Case-insensitive tag lookup over a list of candidate keys (given lowercase).
  defp tag(tags, candidates) do
    downcased = Map.new(tags, fn {k, v} -> {String.downcase(k), v} end)
    Enum.find_value(candidates, fn key -> presence(downcased[key]) end)
  end

  defp presence(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp presence(v), do: v

  defp parse_duration_ms(str) when is_binary(str) do
    case Float.parse(str) do
      {seconds, _rest} -> round(seconds * 1000)
      :error -> nil
    end
  end

  defp parse_duration_ms(_), do: nil

  defp parse_bitrate_kbps(value) do
    case parse_int(value) do
      nil -> nil
      bits -> div(bits, 1000)
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_year(str) when is_binary(str) do
    case Regex.run(~r/\d{4}/, str) do
      [year] -> String.to_integer(year)
      _ -> nil
    end
  end

  defp parse_year(_), do: nil

  # "3/12" -> 3
  defp parse_track_no(value), do: parse_int(value)
end
