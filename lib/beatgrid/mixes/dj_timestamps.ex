defmodule Beatgrid.Mixes.DjTimestamps do
  @moduledoc "Parses pasted DJ timestamps ('0:00 DJ A', '1:02:30 DJ B') into ms boundaries."

  @type entry :: %{start_ms: integer(), dj_name: String.t() | nil}

  @spec parse(String.t() | nil) :: [entry()]
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
    |> Enum.sort_by(& &1.start_ms)
  end

  def parse(_), do: []

  defp parse_line(line) do
    case Regex.run(~r/^\s*(\d{1,2}:\d{2}:\d{2}|\d{1,3}:\d{2})\s*(.*)$/, String.trim(line)) do
      [_, clock, name] -> [%{start_ms: clock_ms(clock), dj_name: blank_to_nil(name)}]
      _ -> []
    end
  end

  defp clock_ms(clock) do
    parts = clock |> String.split(":") |> Enum.map(&String.to_integer/1)

    secs =
      case parts do
        [h, m, s] -> h * 3600 + m * 60 + s
        [m, s] -> m * 60 + s
      end

    secs * 1000
  end

  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
