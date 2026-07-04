defmodule Beatgrid.Sets.TransitionChooser do
  @moduledoc """
  Picks the DJ transition to mix one track into the next, from three signals — the
  BPM jump (with direction), Camelot harmony, and the energy change — so the set
  varies across the seven transitions instead of always defaulting to echo.

  Pure calculation over already-resolved effective values (`%{bpm, camelot,
  energy}`) plus the outro/intro markers. Returns `{type, reason}`, the reason a
  human-readable sentence shown in the UI to demystify the automatic choice.

  Order matters: the dramatic tempo cases come first (the vinyl brake stays RARE,
  only on big jumps, as every DJ recommends); close-BPM pairs fall into the matched
  family, decided by energy then harmony.
  """

  alias Beatgrid.Mixing

  @type eff :: %{bpm: number() | nil, camelot: String.t() | nil, energy: number() | nil}

  @doc """
  Chooses `{type, reason}` for mixing `a` into `b`. With either marker missing
  there is nothing to beat-match on, so it degrades to a plain `cut`.
  """
  @spec choose(eff(), eff(), map() | nil, map() | nil) :: {String.t(), String.t()}
  def choose(_a, _b, out, intro) when is_nil(out) or is_nil(intro) do
    {"cut", "Sem marcadores de saída/entrada — corte seco no tempo."}
  end

  def choose(a, b, _out, _intro), do: choose_by_signal(a, b)

  defp choose_by_signal(a, b) do
    delta = bpm_delta(a.bpm, b.bpm)

    cond do
      delta > 0.13 ->
        {"brake", "Salto forte de BPM (#{pct(delta)}) — o freio de vinil marca a virada."}

      delta < -0.13 ->
        {"lowpass", "Queda forte de BPM (#{pct(delta)}) — afunda a faixa que sai."}

      abs(delta) > 0.08 ->
        {"echo", "BPMs diferentes (#{pct(delta)}) — a cauda de eco disfarça o salto."}

      true ->
        choose_close(a, b)
    end
  end

  # BPMs próximos: energia (só quando ambas conhecidas) manda no filtro/fade,
  # senão a harmonia decide entre mix casado e troca de grave.
  defp choose_close(a, b) do
    harm = Mixing.harmony(a.camelot, b.camelot)
    d_energy = energy_delta(a.energy, b.energy)

    cond do
      is_number(d_energy) and d_energy > 0.12 ->
        {"filter", "Subindo a energia com BPM próximo — o filtro abre a entrada."}

      is_number(d_energy) and d_energy < -0.12 ->
        {"fade", "Baixando a energia — fade suave entre as faixas."}

      # Compatível OU desconhecido (0.5 neutro): o mix casado é seguro.
      harm >= 0.5 ->
        {"crossfade", "BPMs próximos e tons compatíveis — mix casado no overlap."}

      # Choque de tom detectado (vizinhos distantes na roda Camelot).
      true ->
        {"bass_swap", "BPMs próximos, mas tons que brigam — troca de grave evita o choque."}
    end
  end

  # Variação relativa de BPM com sinal: >0 acelera, <0 desacelera.
  defp bpm_delta(a, b) when is_number(a) and is_number(b) and a > 0 and b > 0, do: (b - a) / a
  defp bpm_delta(_a, _b), do: 0.0

  # Só compara energia quando AMBAS têm o valor real do Soundcharts (mesma escala
  # 0–1, clampeado contra imports fora do intervalo); nil = pular.
  defp energy_delta(a, b) when is_number(a) and is_number(b), do: clamp01(b) - clamp01(a)
  defp energy_delta(_a, _b), do: nil

  defp clamp01(v), do: v |> max(0.0) |> min(1.0)

  defp pct(delta), do: "#{if delta > 0, do: "+", else: ""}#{round(delta * 100)}%"
end
