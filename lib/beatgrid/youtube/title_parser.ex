defmodule Beatgrid.YouTube.TitleParser do
  @moduledoc """
  Best-effort `"Artist - Title"` extraction from a (messy) YouTube video title:
  strips noise tags like `(Official Video)`, `[HD]`, `(Áudio Oficial)` and splits
  on the first " - ". Pure heuristic — ambiguous cases are refined later by the AI
  during enrichment, and the DJ can always fix the rest in the Central de Revisão.
  """

  # A parenthetical/bracketed group is dropped only when it contains a noise word,
  # so meaningful ones (e.g. "Trevo (Tu)") survive.
  @noise ~r/[\(\[][^\)\]]*\b(?:official|oficial|video|v[íi]deo|[áa]udio|lyrics?|letra|hd|4k|mv|visualizer|clipe|remaster(?:ed)?|explicit)\b[^\)\]]*[\)\]]/iu

  @separator ~r/\s+[-–—]\s+/u

  @spec parse(String.t() | nil) :: %{artist: String.t() | nil, title: String.t()}
  def parse(raw) when is_binary(raw) do
    cleaned = raw |> strip_noise() |> collapse()

    case String.split(cleaned, @separator, parts: 2) do
      [artist, title] when artist != "" and title != "" ->
        %{artist: String.trim(artist), title: String.trim(title)}

      _ ->
        %{artist: nil, title: cleaned}
    end
  end

  def parse(_other), do: %{artist: nil, title: ""}

  defp strip_noise(s), do: Regex.replace(@noise, s, "")
  defp collapse(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()
end
