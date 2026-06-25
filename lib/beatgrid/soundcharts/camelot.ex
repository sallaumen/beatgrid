defmodule Beatgrid.Soundcharts.Camelot do
  @moduledoc """
  Maps a pitch-class key (0=C … 11=B) plus mode (1=major, 0=minor) to a Camelot
  wheel code (e.g. `8B`, `10A`) — the notation DJs use for harmonic mixing.
  """

  # key index => Camelot code
  @major %{
    0 => "8B",
    1 => "3B",
    2 => "10B",
    3 => "5B",
    4 => "12B",
    5 => "7B",
    6 => "2B",
    7 => "9B",
    8 => "4B",
    9 => "11B",
    10 => "6B",
    11 => "1B"
  }

  @minor %{
    0 => "5A",
    1 => "12A",
    2 => "7A",
    3 => "2A",
    4 => "9A",
    5 => "4A",
    6 => "11A",
    7 => "6A",
    8 => "1A",
    9 => "8A",
    10 => "3A",
    11 => "10A"
  }

  @spec from_key(integer() | nil, integer() | nil) :: String.t() | nil
  def from_key(key, 1) when is_integer(key), do: Map.get(@major, key)
  def from_key(key, 0) when is_integer(key), do: Map.get(@minor, key)
  def from_key(_key, _mode), do: nil

  @doc """
  Harmonically compatible Camelot codes for `code`: itself, ±1 around the wheel
  (same letter, wrapping 12↔1), and the relative major/minor (same number, A↔B).
  Returns `[]` for an invalid code.
  """
  @spec neighbors(String.t() | nil) :: [String.t()]
  def neighbors(code) do
    case parse(code) do
      {number, letter} ->
        Enum.uniq([
          code,
          format(wrap(number - 1), letter),
          format(wrap(number + 1), letter),
          format(number, flip(letter))
        ])

      :error ->
        []
    end
  end

  @doc "Whether two Camelot codes mix harmonically."
  @spec compatible?(String.t() | nil, String.t() | nil) :: boolean()
  def compatible?(a, b), do: b in neighbors(a)

  defp parse(code) when is_binary(code) do
    case Regex.run(~r/^(\d{1,2})([AB])$/, code) do
      [_, number, letter] ->
        n = String.to_integer(number)
        if n in 1..12, do: {n, letter}, else: :error

      _ ->
        :error
    end
  end

  defp parse(_code), do: :error

  # 0 → 12, 13 → 1
  defp wrap(n), do: rem(n - 1 + 12, 12) + 1
  defp flip("A"), do: "B"
  defp flip("B"), do: "A"
  defp format(number, letter), do: "#{number}#{letter}"
end
