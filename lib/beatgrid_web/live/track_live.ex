defmodule BeatgridWeb.TrackLive do
  @moduledoc "Detalhe da faixa — metadata, rating, tags, note, harmonic next track."
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.Tracks
  alias Beatgrid.Mixing

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Tracks.get_with_song(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Faixa não encontrada.") |> push_navigate(to: ~p"/")}

      track ->
        {:ok,
         assign(socket,
           track: track,
           next: Mixing.suggest_next(track, limit: 8),
           tag_draft: "",
           page_title: title(track)
         )}
    end
  end

  @impl true
  def handle_event("set_rating", %{"n" => n}, socket) do
    {:noreply, save(socket, %{rating: String.to_integer(n)})}
  end

  def handle_event("add_tag", %{"tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply, socket}
    else
      tags = Enum.uniq((socket.assigns.track.tags || []) ++ [tag])
      {:noreply, socket |> save(%{tags: tags}) |> assign(tag_draft: "")}
    end
  end

  def handle_event("remove_tag", %{"tag" => tag}, socket) do
    {:noreply, save(socket, %{tags: (socket.assigns.track.tags || []) -- [tag]})}
  end

  def handle_event("save_note", %{"note" => note}, socket) do
    {:noreply, save(socket, %{personal_note: note})}
  end

  defp save(socket, attrs) do
    {:ok, _} = Tracks.update(socket.assigns.track, attrs)
    assign(socket, track: Tracks.get_with_song(socket.assigns.track.id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:biblioteca}>
      <div class="mx-auto max-w-5xl px-6 py-5">
        <.link navigate={~p"/"} class="text-body-sm text-ink-muted hover:text-ink">
          ← Biblioteca
        </.link>

        <header class="mt-4 flex gap-5">
          <.cover artist={@track.tag_artist} size={84} />
          <div class="min-w-0 flex-1">
            <h1 class="truncate text-[23px] font-semibold">{title(@track)}</h1>
            <p class="text-body-lg text-ink-secondary">{@track.tag_artist || "—"}</p>
            <div class="mt-3 flex items-center gap-4">
              <.folder_badge :if={@track.genre_folder} folder={@track.genre_folder} />
              <.stat label="BPM" value={bpm(@track)} class="text-primary" />
              <div class="flex items-center gap-1.5">
                <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">Tom</span>
                <.camelot_seal value={camelot(@track)} />
              </div>
              <.confidence_chip level={@track.sc_match_confidence} />
            </div>
          </div>
        </header>

        <div class="mt-6 grid grid-cols-1 gap-5 lg:grid-cols-2">
          <section class="rounded-xl border border-white/6 bg-surface p-4">
            <.section_label>Metadados</.section_label>
            <dl class="mt-3 space-y-1.5">
              <div :for={{k, v} <- meta_rows(@track)} class="flex justify-between gap-4 text-body-sm">
                <dt class="text-ink-faint">{k}</dt>
                <dd class="truncate text-right text-ink-secondary">{v}</dd>
              </div>
            </dl>
            <.audio_profile :if={@track.soundcharts_song} song={@track.soundcharts_song} />
          </section>

          <div class="space-y-5">
            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Minha nota</.section_label>
              <div class="mt-3"><.rating_control value={@track.rating} /></div>
            </section>

            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Minhas tags</.section_label>
              <div class="mt-3 flex flex-wrap gap-1.5">
                <span
                  :for={tag <- @track.tags || []}
                  class="inline-flex items-center gap-1 rounded-sm border border-primary/40 bg-primary/15 px-2 py-1 text-[11px] text-ink"
                >
                  {tag}
                  <button
                    phx-click="remove_tag"
                    phx-value-tag={tag}
                    class="text-ink-muted hover:text-coral"
                  >✕</button>
                </span>
                <span :if={(@track.tags || []) == []} class="text-body-sm text-ink-faint">Sem tags ainda.</span>
              </div>
              <form id="track-add-tag" phx-submit="add_tag" class="mt-2.5 flex gap-2">
                <input
                  type="text"
                  name="tag"
                  value={@tag_draft}
                  placeholder="+ nova tag"
                  class="flex-1 rounded-md border border-white/8 bg-input px-2.5 py-1.5 text-body-sm focus:border-primary/50 focus:outline-none"
                />
                <button class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white">Adicionar</button>
              </form>
            </section>

            <section class="rounded-xl border border-white/6 bg-surface p-4">
              <.section_label>Anotação pessoal</.section_label>
              <form id="track-note" phx-change="save_note" class="mt-3">
                <textarea
                  name="note"
                  rows="3"
                  phx-debounce="600"
                  placeholder="Observações suas sobre a faixa…"
                  class="w-full resize-none rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
                >{@track.personal_note}</textarea>
              </form>
            </section>
          </div>
        </div>

        <section class="mt-6 rounded-xl border border-white/6 bg-surface p-4">
          <.section_label>Próxima faixa ideal (harmônica)</.section_label>
          <div :if={@next != []} class="mt-3 space-y-1">
            <.link
              :for={s <- @next}
              navigate={~p"/track/#{s.track.id}"}
              class="flex items-center gap-3 rounded-lg px-2 py-2 hover:bg-surface-2"
            >
              <.cover artist={s.track.tag_artist} size={34} />
              <div class="min-w-0 flex-1">
                <p class="truncate text-body font-medium">{title(s.track)}</p>
                <p class="truncate text-caption text-ink-muted">{s.track.tag_artist || "—"}</p>
              </div>
              <.camelot_seal value={s.camelot} />
              <span class="w-12 text-right font-mono text-body text-primary">{round(s.bpm)}</span>
            </.link>
          </div>
          <p :if={@next == []} class="mt-3 text-body-sm text-ink-faint">
            Sem sugestões harmônicas (faixa sem tom/BPM, ou nada compatível).
          </p>
        </section>
      </div>
    </.app_shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: ""

  defp stat(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">{@label}</span>
      <span class={["font-mono text-body-lg", @class]}>{@value}</span>
    </div>
    """
  end

  slot :inner_block, required: true

  defp section_label(assigns) do
    ~H"""
    <span class="text-[10px] font-semibold uppercase tracking-wider text-ink-faint">
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :song, :any, required: true

  defp audio_profile(assigns) do
    ~H"""
    <div class="mt-4 space-y-2">
      <.section_label>Perfil de áudio</.section_label>
      <.feature_bar :for={{label, value} <- audio_features(@song)} label={label} value={value} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :float, required: true

  defp feature_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class="w-24 text-[11px] text-ink-muted">{@label}</span>
      <div class="h-[6px] flex-1 rounded-full bg-white/5">
        <div class="h-full rounded-full bg-green" style={"width:#{round(@value * 100)}%"} />
      </div>
      <span class="w-8 text-right font-mono text-[11px] text-ink-secondary">{round(@value * 100)}</span>
    </div>
    """
  end

  defp audio_features(song) do
    [
      {"Energia", song.energy},
      {"Valência", song.valence},
      {"Dançabilidade", song.danceability},
      {"Acústico", song.acousticness}
    ]
    |> Enum.filter(fn {_l, v} -> is_number(v) end)
  end

  defp meta_rows(track) do
    (base_rows(track) ++ song_rows(track.soundcharts_song))
    |> Enum.reject(fn {_k, v} -> v in [nil, "", false] end)
  end

  defp base_rows(track) do
    [
      {"Pasta", folder_label(track.genre_folder)},
      {"Duração", track.duration_ms && format_secs(div(track.duration_ms, 1000))},
      {"Formato", track.format},
      {"Bitrate", track.bitrate_kbps && "#{track.bitrate_kbps} kbps"},
      {"Arquivo", track.rel_path}
    ]
  end

  defp song_rows(nil), do: []

  defp song_rows(song) do
    [
      {"Artista (nuvem)", song.credit_name},
      {"ISRC", song.isrc},
      {"Ano", song.release_date && song.release_date.year},
      {"Gravadora", song.label},
      {"Gêneros", genres(song)},
      {"Compasso", song.time_signature && "#{song.time_signature}/4"},
      {"Idioma", song.language_code}
    ]
  end

  defp genres(song) do
    case Enum.uniq((song.subgenres || []) ++ (song.genres || [])) do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp format_secs(s), do: "#{div(s, 60)}:#{String.pad_leading(to_string(rem(s, 60)), 2, "0")}"

  defp title(track), do: track.tag_title || track.filename

  defp bpm(%{soundcharts_song: %{tempo_bpm: bpm}}) when is_number(bpm), do: round(bpm)
  defp bpm(_track), do: "—"

  defp camelot(%{soundcharts_song: %{camelot: c}}), do: c
  defp camelot(_track), do: nil
end
