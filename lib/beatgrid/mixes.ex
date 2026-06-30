defmodule Beatgrid.Mixes do
  @moduledoc """
  Online DJ sets ("mixes") imported for study: a `Mix` (the recorded set) and its
  ordered `Segment`s (the tracks within it). This module is the data/query boundary;
  download, audio analysis, and AI naming live in their own ports/workers.
  """
  import Ecto.Query
  require Logger

  alias Beatgrid.Integrations
  alias Beatgrid.Library
  alias Beatgrid.Library.{Normalize, Track}
  alias Beatgrid.Mixes.{DjPart, DjTimestamps, Mix, Segment}
  alias Beatgrid.Repo

  alias Beatgrid.Workers.{
    MixAnalyzeWorker,
    MixDjAudioWorker,
    MixDjVisionWorker,
    MixDownloadWorker,
    MixRecognizeWorker
  }

  @adapter Application.compile_env(
             :beatgrid,
             [Beatgrid.Mixes.Source, :adapter],
             Beatgrid.Mixes.Source.YtDlp
           )
  @topic "mixes"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Beatgrid.PubSub, @topic)

  @spec broadcast(map()) :: :ok
  def broadcast(payload),
    do: Phoenix.PubSub.broadcast(Beatgrid.PubSub, @topic, {:mix_progress, payload})

  @spec detect_source(String.t()) :: {:ok, String.t()} | {:error, :unsupported_source}
  def detect_source(url) when is_binary(url) do
    case URI.parse(url).host do
      nil -> {:error, :unsupported_source}
      host -> classify_host(String.downcase(host))
    end
  end

  def detect_source(_), do: {:error, :unsupported_source}

  defp classify_host(host) do
    cond do
      host in ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"] ->
        {:ok, "youtube"}

      host == "soundcloud.com" or String.ends_with?(host, ".soundcloud.com") ->
        {:ok, "soundcloud"}

      true ->
        {:error, :unsupported_source}
    end
  end

  @spec import_url(String.t()) ::
          {:ok, Mix.t()} | {:error, :unsupported_source | Ecto.Changeset.t()}
  def import_url(url) do
    with {:ok, source} <- detect_source(url),
         {:ok, mix} <- create_mix(%{source: source, source_url: url, status: :downloading}),
         {:ok, _job} <- Oban.insert(MixDownloadWorker.new(%{mix_id: mix.id})) do
      {:ok, mix}
    end
  end

  @spec fetch_source(String.t(), String.t()) ::
          {:ok, Beatgrid.Mixes.Source.meta()} | {:error, term()}
  def fetch_source(url, dest_dir), do: @adapter.fetch(url, dest_dir)

  @spec update_mix(Mix.t(), map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def update_mix(%Mix{} = mix, attrs), do: mix |> Mix.changeset(attrs) |> Repo.update()

  @spec create_mix(map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def create_mix(attrs), do: %Mix{} |> Mix.changeset(attrs) |> Repo.insert()

  @spec get_mix(binary()) :: Mix.t() | nil
  def get_mix(id), do: Repo.get(Mix, id)

  @spec get_with_segments(binary()) :: Mix.t() | nil
  def get_with_segments(id) do
    Mix
    |> Repo.get(id)
    |> Repo.preload(segments: from(s in Segment, order_by: [asc: s.position]))
  end

  @spec list_mixes() :: [Mix.t()]
  def list_mixes, do: Repo.all(from m in Mix, order_by: [desc: m.inserted_at])

  @spec create_segment(map()) :: {:ok, Segment.t()} | {:error, Ecto.Changeset.t()}
  def create_segment(attrs), do: %Segment{} |> Segment.changeset(attrs) |> Repo.insert()

  @spec update_segment(Segment.t(), map()) :: {:ok, Segment.t()} | {:error, Ecto.Changeset.t()}
  def update_segment(%Segment{} = segment, attrs),
    do: segment |> Segment.changeset(attrs) |> Repo.update()

  @spec set_status(Mix.t(), atom(), map()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def set_status(%Mix{} = mix, status, extra \\ %{}),
    do: update_mix(mix, Map.put(extra, :status, status))

  @doc "Replaces all of a mix's segments with the given attrs (in a transaction)."
  @spec replace_segments(Mix.t(), [map()]) :: {:ok, non_neg_integer()}
  def replace_segments(%Mix{id: mix_id}, segments) do
    Repo.transaction(fn ->
      Repo.delete_all(from s in Segment, where: s.mix_id == ^mix_id)

      Enum.each(segments, fn attrs ->
        %Segment{} |> Segment.changeset(Map.put(attrs, :mix_id, mix_id)) |> Repo.insert!()
      end)

      length(segments)
    end)
  end

  @doc "Deletes the cached audio file (only under _Mixes), keeping the analysis."
  @spec purge_audio(Mix.t()) :: {:ok, Mix.t()} | {:error, Ecto.Changeset.t()}
  def purge_audio(%Mix{audio_path: path} = mix) do
    if is_binary(path) and under_mixes_dir?(path) and File.exists?(path), do: File.rm(path)

    update_mix(mix, %{
      audio_path: nil,
      cleanup_job_id: nil,
      audio_deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  @doc "Re-fetches a purged audio file from its source (restore-only: no re-analysis)."
  @spec redownload_audio(Mix.t()) :: {:ok, Mix.t()} | {:error, term()}
  def redownload_audio(%Mix{} = mix) do
    with {:ok, updated} <- update_mix(mix, %{status: :downloading}),
         {:ok, _job} <- Oban.insert(MixDownloadWorker.new(%{mix_id: mix.id, restore_only: true})) do
      {:ok, updated}
    end
  end

  @spec get_with_dj_parts(binary()) :: Mix.t() | nil
  def get_with_dj_parts(id) do
    Mix
    |> Repo.get(id)
    |> Repo.preload(
      segments: from(s in Segment, order_by: [asc: s.position]),
      dj_parts: from(p in DjPart, order_by: [asc: p.position])
    )
  end

  @spec group_by_dj([Segment.t()], [DjPart.t()]) :: [{DjPart.t() | nil, [Segment.t()]}]
  def group_by_dj(segments, dj_parts) do
    segments
    |> Enum.group_by(fn seg ->
      Enum.find(dj_parts, &(seg.start_ms >= &1.start_ms and seg.start_ms < &1.end_ms))
    end)
    |> Enum.sort_by(fn {part, _segs} -> if part, do: part.start_ms, else: :infinity end)
  end

  @spec snap_to_segment_starts([integer()], [Segment.t()]) :: [integer()]
  def snap_to_segment_starts(boundaries, segments) do
    boundaries |> Enum.map(&snap_start(&1, segments)) |> Enum.uniq() |> Enum.sort()
  end

  defp snap_start(b, []), do: b

  defp snap_start(b, segments),
    do: segments |> Enum.map(& &1.start_ms) |> Enum.min_by(&abs(&1 - b))

  @spec clear_dj_parts(Mix.t()) :: {non_neg_integer(), nil}
  def clear_dj_parts(%Mix{id: id}), do: Repo.delete_all(from p in DjPart, where: p.mix_id == ^id)

  @spec set_dj_parts_manual(Mix.t(), String.t()) :: {:ok, non_neg_integer()}
  def set_dj_parts_manual(%Mix{} = mix, text) do
    parts =
      text |> DjTimestamps.parse() |> Enum.map(&%{start_ms: &1.start_ms, dj_name: &1.dj_name})

    do_replace_dj_parts(mix, :manual, parts)
  end

  @spec replace_dj_parts(Mix.t(), atom(), [map()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, :manual_present}
  def replace_dj_parts(mix, source, parts, opts \\ [])

  def replace_dj_parts(%Mix{} = mix, source, parts, opts)
      when source in [:chapter, :image, :audio] do
    if has_manual_dj_parts?(mix),
      do: {:error, :manual_present},
      else: do_replace_dj_parts(mix, source, parts, opts)
  end

  def replace_dj_parts(%Mix{} = mix, :manual, parts, opts),
    do: do_replace_dj_parts(mix, :manual, parts, opts)

  defp has_manual_dj_parts?(%Mix{id: id}),
    do: Repo.exists?(from p in DjPart, where: p.mix_id == ^id and p.source == :manual)

  defp do_replace_dj_parts(%Mix{id: id} = mix, source, parts, opts \\ []) do
    segments = Repo.all(from s in Segment, where: s.mix_id == ^id, order_by: [asc: s.start_ms])
    duration = mix.duration_ms || end_of(segments)

    snapped =
      parts
      |> Enum.sort_by(& &1.start_ms)
      |> Enum.map(fn p -> %{start_ms: snap_start(p.start_ms, segments), dj_name: p.dj_name} end)

    snapped =
      if Enum.any?(snapped, &(&1.start_ms == 0)),
        do: snapped,
        else: [%{start_ms: 0, dj_name: nil} | snapped]

    deduped =
      snapped
      |> Enum.group_by(& &1.start_ms)
      |> Enum.map(fn {_start, entries} -> Enum.find(entries, & &1.dj_name) || hd(entries) end)
      |> Enum.sort_by(& &1.start_ms)

    if length(deduped) < length(snapped) do
      Logger.info(
        "dj_parts: snapping collapsed #{length(snapped) - length(deduped)} overlapping part(s) for mix #{id}"
      )
    end

    # When OCR/audio detection covered only part of the set, mark the uncovered tail as
    # "no DJ" instead of stretching the last detected DJ across frames we never read.
    # Done AFTER dedup, snapping the boundary FORWARD, so it can never collapse onto the
    # last detected DJ's start and silently re-stretch it.
    deduped = maybe_append_coverage_tail(deduped, opts[:coverage_until_ms], segments, duration)

    rows =
      deduped
      |> Enum.with_index()
      |> Enum.map(fn {%{start_ms: start, dj_name: name}, i} ->
        end_ms =
          case Enum.at(deduped, i + 1) do
            nil -> duration
            next -> next.start_ms
          end

        %{position: i, start_ms: start, end_ms: end_ms, dj_name: name, source: source}
      end)

    Repo.transaction(fn ->
      Repo.delete_all(from p in DjPart, where: p.mix_id == ^id)

      Enum.each(rows, fn attrs ->
        %DjPart{} |> DjPart.changeset(Map.put(attrs, :mix_id, id)) |> Repo.insert!()
      end)

      length(rows)
    end)
  end

  defp end_of([]), do: 0
  defp end_of(segments), do: segments |> List.last() |> Map.get(:end_ms) || 0

  defp maybe_append_coverage_tail(parts, cov, segments, duration)
       when is_integer(cov) and cov < duration do
    cov_snapped = snap_forward(cov, segments)
    last_start = parts |> List.last() |> Map.get(:start_ms)

    if cov_snapped > last_start and cov_snapped < duration do
      Enum.sort_by(parts ++ [%{start_ms: cov_snapped, dj_name: nil}], & &1.start_ms)
    else
      parts
    end
  end

  defp maybe_append_coverage_tail(parts, _cov, _segments, _duration), do: parts

  # Snap a coverage boundary to the nearest segment start at or after it (never backward
  # onto an already-detected part). Falls back to the raw boundary past the last segment.
  defp snap_forward(b, segments) do
    case segments |> Enum.map(& &1.start_ms) |> Enum.filter(&(&1 >= b)) do
      [] -> b
      forward -> Enum.min(forward)
    end
  end

  @spec rename_dj_part(binary() | DjPart.t(), String.t() | nil) ::
          {:ok, DjPart.t()} | {:error, term()}
  def rename_dj_part(%DjPart{} = part, name) do
    part |> DjPart.changeset(%{dj_name: blank_to_nil(name)}) |> Repo.update()
  end

  def rename_dj_part(id, name) when is_binary(id) do
    case Repo.get(DjPart, id) do
      nil -> {:error, :not_found}
      part -> rename_dj_part(part, name)
    end
  end

  @spec delete_dj_part(binary() | DjPart.t()) :: {:ok, DjPart.t()} | {:error, term()}
  def delete_dj_part(%DjPart{} = part), do: Repo.delete(part)

  def delete_dj_part(id) when is_binary(id) do
    case Repo.get(DjPart, id) do
      nil -> {:error, :not_found}
      part -> Repo.delete(part)
    end
  end

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp blank_to_nil(_), do: nil

  defp under_mixes_dir?(path) do
    root = Path.expand(Path.join(Library.library_root(), "_Mixes"))
    String.starts_with?(Path.expand(path), root <> "/")
  end

  @spec set_dj_parts_from_chapters(Mix.t()) ::
          {:ok, non_neg_integer()} | {:error, :manual_present | :no_chapters}
  def set_dj_parts_from_chapters(%Mix{chapters: chapters} = mix)
      when is_list(chapters) and chapters != [] do
    parts = Enum.map(chapters, fn c -> %{start_ms: c["start_ms"], dj_name: c["title"]} end)

    with {:ok, n} <- replace_dj_parts(mix, :chapter, parts),
         {:ok, _} <- update_mix(mix, %{chapters_role: :djs}),
         {:ok, _} <- Oban.insert(MixAnalyzeWorker.new(%{mix_id: mix.id})) do
      {:ok, n}
    end
  end

  def set_dj_parts_from_chapters(_mix), do: {:error, :no_chapters}

  @spec analyze_all(Mix.t()) :: {:ok, Oban.Job.t()} | {:error, :no_audio}
  def analyze_all(%Mix{} = mix) do
    if is_binary(mix.audio_path) and is_nil(mix.audio_deleted_at) do
      {:ok, _} = set_status(mix, :analyzing)
      Oban.insert(MixAnalyzeWorker.new(%{mix_id: mix.id, free_djs: true}))
    else
      {:error, :no_audio}
    end
  end

  @spec detect_djs_by_audio(Mix.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def detect_djs_by_audio(%Mix{} = mix),
    do: Oban.insert(MixDjAudioWorker.new(%{mix_id: mix.id}))

  @spec detect_djs_by_image(Mix.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def detect_djs_by_image(%Mix{} = mix),
    do: Oban.insert(MixDjVisionWorker.new(%{mix_id: mix.id}))

  @spec recognize_unnamed(Mix.t(), boolean()) :: {:ok, Oban.Job.t()} | {:error, :no_credentials}
  def recognize_unnamed(%Mix{} = mix, retry_all \\ false) do
    if Integrations.configured?(:audd) do
      args = if retry_all, do: %{mix_id: mix.id, retry_all: true}, else: %{mix_id: mix.id}
      Oban.insert(MixRecognizeWorker.new(args))
    else
      {:error, :no_credentials}
    end
  end

  @spec recognize_segment(Segment.t()) :: {:ok, Oban.Job.t()} | {:error, :no_credentials}
  def recognize_segment(%Segment{} = seg) do
    if Integrations.configured?(:audd),
      do: Oban.insert(MixRecognizeWorker.new(%{segment_id: seg.id})),
      else: {:error, :no_credentials}
  end

  @spec match_track(String.t() | nil, String.t() | nil) ::
          %{track_id: binary(), confidence: :high} | nil
  def match_track(artist, title) do
    na = Normalize.normalize(artist)
    nt = Normalize.normalize(title)

    if na != "" and nt != "" do
      Track
      |> where([t], t.status == :present and t.norm_artist == ^na and t.norm_title == ^nt)
      |> order_by([t], asc: t.inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        nil -> nil
        track -> %{track_id: track.id, confidence: :high}
      end
    end
  end
end
