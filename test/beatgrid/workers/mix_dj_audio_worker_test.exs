defmodule Beatgrid.Workers.MixDjAudioWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Beatgrid.Factory
  import Mox
  setup :verify_on_exit!
  setup :set_mox_global

  alias Beatgrid.Mixes
  alias Beatgrid.Workers.MixDjAudioWorker

  test "turns audio candidates into :audio dj parts" do
    mix = insert(:mix, duration_ms: 600_000, audio_path: "/tmp/_Mixes/a.mp3")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

    expect(Beatgrid.Audio.SetSegmenterMock, :dj_candidates, fn "/tmp/_Mixes/a.mp3" ->
      {:ok, [%{start_ms: 300_000, strength: 0.9}]}
    end)

    assert :ok = perform_job(MixDjAudioWorker, %{mix_id: mix.id})
    parts = Mixes.get_with_dj_parts(mix.id).dj_parts
    assert Enum.map(parts, & &1.start_ms) == [0, 300_000]
    assert Enum.all?(parts, &(&1.source == :audio))
  end
end
