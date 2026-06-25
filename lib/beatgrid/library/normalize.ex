defmodule Beatgrid.Library.Normalize do
  @moduledoc """
  Normalizes free-text artist/title strings into a canonical form for fuzzy
  duplicate matching: lowercased, accent-stripped, punctuation and whitespace
  collapsed to single spaces, trimmed.

      iex> Beatgrid.Library.Normalize.normalize("Águas De Março")
      "aguas de marco"
  """

  @combining_marks ~r/[\x{0300}-\x{036F}]/u
  @non_alphanumeric ~r/[^a-z0-9]+/u

  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: ""

  def normalize(string) when is_binary(string) do
    string
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(@combining_marks, "")
    |> String.replace(@non_alphanumeric, " ")
    |> String.trim()
  end
end
