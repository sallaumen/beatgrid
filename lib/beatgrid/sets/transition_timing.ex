defmodule Beatgrid.Sets.TransitionTiming do
  @moduledoc "Source positions for a mix, derived from the pair's markers, ending and learned decision."
  alias Beatgrid.Library
  alias Beatgrid.Library.Marker

  # Console hint clamps (never-again #4: from_ms is never trusted blindly).
  @default_outro_window_ms 8_000
  @min_tail_ms 3_000
  @max_intro_skip_ms 10_000

  # A hand fire is only a CORRECTION when it departs this far from what the
  # console would already do — anything closer is noise, not a lesson.
  @learn_min_delta_ms 5_000

  @breather_lead_ms 4_000
  @sacred_tail_ms 1_500

  @doc "The effective exit, entry and learned flag for a connected pair."
  @spec resolve(Library.Track.t(), Library.Track.t(), map() | nil) :: map()
  def resolve(outgoing, incoming, transition) do
    {ms, source} = exit_point(outgoing, transition)
    %{from_ms: ms, to_ms: derived_to_ms(incoming), learned?: source == :learned, source: source}
  end

  @doc "The exit position and the decision responsible for it, shared with the set checks."
  @spec exit_point(Library.Track.t(), map() | nil) ::
          {non_neg_integer() | nil, :breather | :learned | :protected | :marker | :fallback}
  def exit_point(outgoing, %{"breather" => true}), do: {breather_from(outgoing), :breather}

  def exit_point(outgoing, transition) do
    cond do
      ms = learned_from(transition || %{}, outgoing) -> {ms, :learned}
      ms = sacred_from(outgoing) -> {ms, :protected}
      true -> marker_exit(outgoing)
    end
  end

  @doc """
  The fire/entry points the console will derive RIGHT NOW for mixing
  `outgoing` into `incoming` — current markers, clamped. What the set editor
  shows with this is exactly what the deck will do.
  """
  @spec derived_timing(Library.Track.t(), Library.Track.t()) ::
          %{from_ms: non_neg_integer() | nil, to_ms: non_neg_integer()}
  def derived_timing(outgoing, incoming) do
    {ms, _source} = marker_exit(outgoing)
    %{from_ms: ms, to_ms: derived_to_ms(incoming)}
  end

  # Uma fronteira de respiro não aprende: o ponto dela é o FIM da música por
  # definição — um disparo manual ali é o DJ pulando o respiro, não uma
  # correção de timing.
  def learnable?(_at_ms, %{"breather" => true}, _outgoing), do: false

  def learnable?(at_ms, transition, %{duration_ms: dur} = outgoing)
      when is_integer(dur) and dur > 0 do
    {current, _source} = exit_point(outgoing, transition)

    at_ms * 2 >= dur and at_ms < dur and abs(at_ms - current) >= @learn_min_delta_ms
  end

  def learnable?(_at_ms, _transition, _outgoing), do: false

  defp breather_from(%{duration_ms: dur}) when is_integer(dur) and dur > 0,
    do: max(dur - @breather_lead_ms, 0)

  defp breather_from(_outgoing), do: nil

  # Curadoria de final: matar esta música cedo é crime — o corte só no talo.
  # O aprendizado humano (um disparo real) ainda vence: ao vivo, a mão manda.
  defp sacred_from(%{sacred_ending: true, duration_ms: dur}) when is_integer(dur) and dur > 0,
    do: max(dur - @sacred_tail_ms, 0)

  defp sacred_from(_outgoing), do: nil

  # O ponto que o DJ ensinou (um disparo real) vence o derivado dos marcadores;
  # só o clamp de cauda se aplica — o piso dos 70% protege contra marcador
  # automático ruim, não contra escolha humana.
  defp learned_from(%{"learned_from_track_id" => expected}, %{id: id}) when expected != id,
    do: nil

  defp learned_from(%{"learned_from_ms" => ms}, %{duration_ms: dur})
       when is_integer(ms) and is_integer(dur) and dur > 0,
       do: ms |> min(dur - @min_tail_ms) |> max(0)

  defp learned_from(_transition, _outgoing), do: nil

  defp marker_exit(%{duration_ms: dur} = outgoing) when is_integer(dur) and dur > 0 do
    {ms, source} = trusted_exit(derived_from_ms(outgoing), dur)
    {ms |> min(dur - @min_tail_ms) |> max(0), source}
  end

  defp marker_exit(outgoing) do
    case derived_from_ms(outgoing) do
      nil -> {nil, :fallback}
      ms -> {ms, :marker}
    end
  end

  defp derived_from_ms(outgoing) do
    case Marker.outro(outgoing) do
      %{"ms" => ms} when is_integer(ms) -> ms
      _missing -> nil
    end
  end

  # Skip a short breath at the head; a LONG quiet opening is real music (live/
  # acoustic intros measured only 6-8dB under the chorus), so play it from 0.
  defp derived_to_ms(incoming) do
    case Marker.intro(incoming) do
      %{"ms" => ms} when is_integer(ms) and ms <= @max_intro_skip_ms -> ms
      _long_or_missing -> 0
    end
  end

  # Only a marker in the final 30% is usable as a mix-out point.
  defp trusted_exit(ms, dur) when is_integer(ms) and ms * 10 >= dur * 7, do: {ms, :marker}
  defp trusted_exit(_untrusted, dur), do: {dur - @default_outro_window_ms, :fallback}
end
