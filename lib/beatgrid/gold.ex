defmodule Beatgrid.Gold do
  @moduledoc """
  Regra única da marca **Ouro** — a música "foda" por dois eixos opostos:
  *rara* (gema fora do streaming) e *popular* (clássico com muita visualização).

  Eixos:
    * **raro** — estado persistido `gold_status` (`:candidate` no import por
      heurística offline; `:confirmed` quando o Soundcharts não acha; rebaixado a
      `nil` quando acha).
    * **popular** — overlay vivo: `youtube_views >= view_threshold()`, derivado na
      leitura pra que mexer no limiar reavalie tudo sem migração.
    * **manual** — `gold_manual` (true/false) vence os dois.

  Não conhece UI nem HTTP: recebe dados/structs e devolve estado.
  """
  alias Beatgrid.Library.{Track, Tracks}
  alias Beatgrid.Settings

  @view_threshold Application.compile_env(:beatgrid, [__MODULE__, :view_threshold], 1_000_000)

  @doc "Limiar de views pra contar como popular (Settings em runtime; default da config)."
  @spec view_threshold() :: integer()
  def view_threshold, do: Settings.get(:gold_view_threshold, @view_threshold)

  @doc "Heurística offline do import: gema rara candidata? (youtube + sem ISRC)."
  @spec candidate?(map() | Track.t()) :: boolean()
  def candidate?(%{source_playlist: "youtube"} = attrs), do: blank?(Map.get(attrs, :tag_isrc))
  def candidate?(_), do: false

  @doc "View count já passa do limiar? (overlay vivo)."
  @spec popular?(Track.t()) :: boolean()
  def popular?(%{youtube_views: v}) when is_integer(v), do: v >= @view_threshold
  def popular?(_), do: false

  @doc """
  Estado efetivo + motivo, pra UI. Manual vence; depois popular; depois o eixo raro.
  """
  @spec effective(Track.t()) ::
          {boolean(), :manual | :popular | :raro_confirmado | :raro_candidato | nil}
  def effective(track) do
    cond do
      track.gold_manual == true -> {true, :manual}
      track.gold_manual == false -> {false, nil}
      popular?(track) -> {true, :popular}
      track.gold_status == :confirmed -> {true, :raro_confirmado}
      track.gold_status == :candidate -> {true, :raro_candidato}
      true -> {false, nil}
    end
  end

  @doc """
  Transição do eixo raro a partir do retorno bruto de `Soundcharts.resolve_track/1`.
  Achou (qualquer Song) → rebaixa; `:no_match` → confirma; já-ligado/budget → no-op.
  """
  @spec apply_resolve_result(Track.t(), term()) :: {:ok, Track.t()} | :ok
  def apply_resolve_result(track, {:ok, :already_linked}), do: {:ok, track}
  def apply_resolve_result(track, {:ok, _song}), do: set_status(track, nil)
  def apply_resolve_result(track, {:error, :no_match}), do: set_status(track, :confirmed)
  def apply_resolve_result(_track, _other), do: :ok

  @doc """
  Marca `:candidate` só quando o status automático e o manual estão `nil` (não
  rebaixa um `:confirmed` num re-ingest). Idempotente.
  """
  @spec maybe_mark_candidate(Track.t()) :: {:ok, Track.t()}
  def maybe_mark_candidate(%Track{gold_status: nil, gold_manual: nil} = track) do
    if candidate?(track), do: set_status(track, :candidate), else: {:ok, track}
  end

  def maybe_mark_candidate(%Track{} = track), do: {:ok, track}

  defp set_status(track, status) do
    {:ok, _} = Tracks.update(track, %{gold_status: status})
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
