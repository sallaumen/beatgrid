defmodule BeatgridWeb.MixLiveGateTest do
  # async: false — the gate flips the GLOBAL Audd config (api_token: nil).
  # Doing that from an async module races every concurrent test that reads the
  # token (Mixes.recognize_unnamed & friends) — the exact leak config/test.exs
  # warns about, and why this test lives outside the async MixLiveTest.
  use BeatgridWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  test "AudD recognize button + gate when no token", %{conn: conn} do
    original = Application.get_env(:beatgrid, Beatgrid.Recognition.Audd)

    on_exit(fn ->
      Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, original || [])
    end)

    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil)

    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 60_000,
      artist: nil,
      title: nil
    )

    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "Reconhecer faixas"
    assert html =~ "AUDD_API_TOKEN"
  end
end
