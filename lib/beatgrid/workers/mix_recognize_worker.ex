defmodule Beatgrid.Workers.MixRecognizeWorker do
  @moduledoc """
  Identifies unnamed segments of a mix via the Recognition port (AudD). Button-triggered, paid.

  Recognition is rate-limited and matches poorly on live sets, so the batch path is careful:
  it targets only segments never attempted before (unless `retry_all`), calls AudD serially
  with a throttle, retries transient failures with backoff, stamps `audd_attempted_at` on a
  no-match so it is not re-paid for next time, and broadcasts a matched/no_match/error tally.
  """
  use Oban.Worker,
    queue: :mixes,
    max_attempts: 3,
    unique: [
      period: 3600,
      keys: [:mix_id, :segment_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Beatgrid.{Integrations, Mixes}
  alias Beatgrid.Mixes.{MixQuery, Segment}

  @recognizer Application.compile_env(
                :beatgrid,
                [Beatgrid.Recognition, :adapter],
                Beatgrid.Recognition.Audd
              )

  @spec enqueue(Beatgrid.Mixes.Mix.t() | Segment.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(target, opts \\ [])

  def enqueue(%Beatgrid.Mixes.Mix{id: id}, opts) do
    args = if opts[:retry_all], do: %{mix_id: id, retry_all: true}, else: %{mix_id: id}
    args |> new() |> Oban.insert()
  end

  def enqueue(%Segment{id: id}, _opts), do: %{segment_id: id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if Integrations.configured?(:audd), do: run(args), else: {:cancel, :no_credentials}
  end

  # Manual single segment: always (re-)attempt it, even if previously tried — the user asked.
  defp run(%{"segment_id" => sid}) do
    case MixQuery.get_segment_with_mix(sid) do
      %Segment{mix: %{audio_path: path, audio_deleted_at: nil} = mix} = seg
      when is_binary(path) ->
        unless named?(seg), do: identify_segment(seg, path)
        Mixes.broadcast(%{mix_id: mix.id, status: :recognized})
        :ok

      _ ->
        {:cancel, :audio_unavailable}
    end
  end

  defp run(%{"mix_id" => mix_id} = args) do
    case Mixes.get_with_segments(mix_id) do
      %{audio_path: path, audio_deleted_at: nil} = mix when is_binary(path) ->
        retry_all = args["retry_all"] == true
        targets = Enum.filter(mix.segments, &target?(&1, retry_all))
        total = length(targets)

        tally =
          targets
          |> Enum.with_index(1)
          |> Enum.reduce(
            %{matched: 0, no_match: 0, error: 0},
            &recognize_one(&1, path, total, mix_id, &2)
          )

        Logger.info(
          "recognize mix #{mix_id}: matched=#{tally.matched} no_match=#{tally.no_match} error=#{tally.error} of #{total}",
          mix_id: mix_id
        )

        Mixes.broadcast(%{
          mix_id: mix_id,
          stage: "recognize_done",
          matched: tally.matched,
          no_match: tally.no_match,
          error: tally.error,
          total: total
        })

        :ok

      _ ->
        {:cancel, :audio_unavailable}
    end
  end

  defp recognize_one({seg, i}, path, total, mix_id, acc) do
    outcome = identify_segment(seg, path)
    Mixes.broadcast(%{mix_id: mix_id, stage: "recognize", done: i, total: total})
    maybe_throttle(i, total)
    Map.update!(acc, outcome, &(&1 + 1))
  end

  defp maybe_throttle(i, total) when i < total, do: throttle()
  defp maybe_throttle(_i, _total), do: :ok

  # A segment is a target when it has no name and either we're forcing a full retry or it has
  # never been attempted — so re-clicking doesn't re-pay AudD for known no-matches.
  defp target?(seg, retry_all),
    do: not named?(seg) and (retry_all or is_nil(seg.audd_attempted_at))

  # Returns :matched | :no_match | :error.
  defp identify_segment(seg, path) do
    case identify_with_retry(path, seg.start_ms, seg.end_ms || seg.start_ms, max_retries()) do
      {:ok, %{artist: a, title: t}} ->
        match = Mixes.match_track(a, t)

        {:ok, _} =
          Mixes.update_segment(seg, %{
            artist: a,
            title: t,
            name_source: :fingerprint,
            matched_track_id: match && match.track_id,
            match_confidence: match && match.confidence,
            audd_attempted_at: now()
          })

        :matched

      {:ok, :no_match} ->
        {:ok, _} = Mixes.update_segment(seg, %{audd_attempted_at: now()})
        :no_match

      {:error, reason} ->
        # Persistent failure: surface it (no more silent ":ok") and leave the segment
        # un-stamped so a later run can try again.
        Logger.warning("recognize segment #{seg.id} failed (giving up): #{inspect(reason)}",
          segment_id: seg.id
        )
        :error
    end
  end

  defp identify_with_retry(path, start_ms, end_ms, retries) do
    case @recognizer.identify(path, start_ms, end_ms) do
      {:error, reason} when retries > 0 ->
        if transient?(reason) do
          retry_sleep(max_retries() - retries + 1)
          identify_with_retry(path, start_ms, end_ms, retries - 1)
        else
          {:error, reason}
        end

      result ->
        result
    end
  end

  # Worth retrying: HTTP 429 / 5xx, transport/timeout exceptions, and AudD rate-limit envelopes.
  defp transient?({:audd_http, status}), do: status == 429 or status in 500..599

  defp transient?({:audd_error, msg}) when is_binary(msg),
    do: String.contains?(String.downcase(msg), ["limit", "rate", "too many"])

  defp transient?(reason) when is_exception(reason), do: true
  defp transient?(_), do: false

  defp throttle, do: sleep(config(:throttle_ms, 2_500))
  defp retry_sleep(attempt), do: sleep(config(:retry_backoff_ms, 2_000) * attempt)
  defp sleep(0), do: :ok
  defp sleep(ms), do: Process.sleep(ms)

  defp max_retries, do: config(:max_retries, 4)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp named?(%{artist: a, title: t}), do: present?(a) or present?(t)
  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  defp config(key, default),
    do: :beatgrid |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
