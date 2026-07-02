defmodule Beatgrid.Workers.MixRecognizeWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Beatgrid.Factory
  import Mox
  setup :verify_on_exit!
  setup :set_mox_global
  alias Beatgrid.Library.Normalize
  alias Beatgrid.Workers.MixRecognizeWorker

  setup do
    # Restore the PRIOR value (the test default is a configured token), not nil — leaving
    # nil here poisons Integrations.configured?(:audd) for every later async test.
    prev = Application.get_env(:beatgrid, Beatgrid.Recognition.Audd)
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: "tok")
    on_exit(fn -> Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, prev) end)
    :ok
  end

  test "fills unnamed segments (:fingerprint) + re-matches; skips named" do
    track =
      insert(:track,
        status: :present,
        tag_artist: "Falamansa",
        tag_title: "Xote",
        norm_artist: Normalize.normalize("Falamansa"),
        norm_title: Normalize.normalize("Xote")
      )

    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 10_000,
      artist: "Já",
      title: "Tem"
    )

    unnamed =
      insert(:mix_segment,
        mix: mix,
        position: 1,
        start_ms: 10_000,
        end_ms: 20_000,
        artist: nil,
        title: nil
      )

    expect(Beatgrid.Recognition.Mock, :identify, fn "/tmp/_Mixes/x.mp3", 10_000, 20_000 ->
      {:ok, %{artist: "Falamansa", title: "Xote"}}
    end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    seg = Beatgrid.Repo.get(Beatgrid.Mixes.Segment, unnamed.id)
    assert seg.artist == "Falamansa" and seg.name_source == :fingerprint
    assert seg.matched_track_id == track.id
  end

  test "no token -> cancels without calling the recognizer" do
    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil)
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 10_000,
      artist: nil,
      title: nil
    )

    assert {:cancel, :no_credentials} = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
  end

  test "segment_id job on an already-named segment is a no-op (never overwrites)" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    named =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: "Keep",
        title: "Me"
      )

    # No Mock expectation: verify_on_exit! fails if identify/3 is called.
    assert :ok = perform_job(MixRecognizeWorker, %{segment_id: named.id})
    seg = Beatgrid.Repo.get(Beatgrid.Mixes.Segment, named.id)
    assert seg.artist == "Keep" and seg.title == "Me"
  end

  defp seg(id), do: Beatgrid.Repo.get(Beatgrid.Mixes.Segment, id)

  test "a no-match stamps audd_attempted_at and leaves the segment unnamed" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    s =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: nil,
        title: nil
      )

    expect(Beatgrid.Recognition.Mock, :identify, fn _p, _s, _e -> {:ok, :no_match} end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    reloaded = seg(s.id)
    # AudD didn't name it (no fingerprint), but we record that we tried
    assert reloaded.artist == nil and reloaded.name_source != :fingerprint
    assert reloaded.audd_attempted_at != nil
  end

  test "the batch skips segments AudD already tried (no-match) — no wasted API call" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    fresh =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: nil,
        title: nil
      )

    insert(:mix_segment,
      mix: mix,
      position: 1,
      start_ms: 10_000,
      end_ms: 20_000,
      artist: nil,
      title: nil,
      audd_attempted_at: ~U[2026-06-30 00:00:00Z]
    )

    # exactly ONE identify call (for the fresh segment); the already-tried one is skipped
    expect(Beatgrid.Recognition.Mock, :identify, fn _p, 0, 10_000 -> {:ok, :no_match} end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    assert seg(fresh.id).audd_attempted_at != nil
  end

  test "retry_all re-attempts segments already tried" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    tried =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: nil,
        title: nil,
        audd_attempted_at: ~U[2026-06-30 00:00:00Z]
      )

    expect(Beatgrid.Recognition.Mock, :identify, fn _p, _s, _e ->
      {:ok, %{artist: "Found", title: "Now"}}
    end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id, retry_all: true})
    assert seg(tried.id).artist == "Found" and seg(tried.id).name_source == :fingerprint
  end

  test "a transient error (HTTP 429) is retried, then succeeds" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    s =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: nil,
        title: nil
      )

    Beatgrid.Recognition.Mock
    |> expect(:identify, fn _p, _s, _e -> {:error, {:audd_http, 429}} end)
    |> expect(:identify, fn _p, _s, _e -> {:ok, %{artist: "A", title: "B"}} end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    assert seg(s.id).artist == "A"
  end

  test "a permanent error is not retried, not stamped (so it can be tried later)" do
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    s =
      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        end_ms: 10_000,
        artist: nil,
        title: nil
      )

    # exactly ONE call — a non-transient error must not retry
    expect(Beatgrid.Recognition.Mock, :identify, fn _p, _s, _e ->
      {:error, {:ffmpeg_exit, 1, "boom"}}
    end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})
    reloaded = seg(s.id)
    assert reloaded.artist == nil
    assert reloaded.audd_attempted_at == nil
  end

  test "broadcasts a final summary tally" do
    Beatgrid.Mixes.subscribe()
    mix = insert(:mix, audio_path: "/tmp/_Mixes/x.mp3")

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 10_000,
      artist: nil,
      title: nil
    )

    insert(:mix_segment,
      mix: mix,
      position: 1,
      start_ms: 10_000,
      end_ms: 20_000,
      artist: nil,
      title: nil
    )

    Beatgrid.Recognition.Mock
    |> expect(:identify, fn _p, 0, 10_000 -> {:ok, %{artist: "A", title: "B"}} end)
    |> expect(:identify, fn _p, 10_000, 20_000 -> {:ok, :no_match} end)

    assert :ok = perform_job(MixRecognizeWorker, %{mix_id: mix.id})

    assert_receive {:mix_progress,
                    %{stage: "recognize_done", matched: 1, no_match: 1, error: 0, total: 2}}
  end
end
