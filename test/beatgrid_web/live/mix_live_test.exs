defmodule BeatgridWeb.MixLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Library.Normalize
  alias Beatgrid.Mixes.Segment
  alias Beatgrid.Repo
  alias Beatgrid.Workers.MixAnalyzeWorker

  test "renders the segment timeline with names, BPM, Camelot and the transition map", %{
    conn: conn
  } do
    track = insert(:track, status: :present, tag_artist: "A", tag_title: "One")
    mix = insert(:mix, title: "Live Set", dj: "DJ X", status: :ready)

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      artist: "A",
      title: "One",
      bpm_detected: 124.0,
      camelot_detected: "8A",
      matched_track_id: track.id,
      match_confidence: :high
    )

    insert(:mix_segment,
      mix: mix,
      position: 1,
      start_ms: 270_000,
      artist: "B",
      title: "Two",
      bpm_detected: 126.0,
      camelot_detected: "9A"
    )

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")

    assert html =~ "Live Set"
    assert html =~ "A" and html =~ "One" and html =~ "Two"
    assert html =~ "8A" and html =~ "9A"
    # 270_000 ms as mm:ss
    assert html =~ "04:30"
    # matched segment badge
    assert html =~ "tenho"
    assert html =~ "/track/#{track.id}"
  end

  test "unnamed unmatched segment shows 'sem nome' instead of a broken empty YouTube link", %{
    conn: conn
  } do
    mix = insert(:mix, status: :ready)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, artist: "Some", title: "Song")
    insert(:mix_segment, mix: mix, position: 1, start_ms: 60_000, artist: nil, title: nil)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")

    # named-but-unmatched → real YouTube search; unnamed → "sem nome", no empty search link
    assert html =~ "não tenho"
    assert html =~ "search_query=Some"
    assert html =~ "sem nome"
    refute html =~ ~s|search_query="|
  end

  test "redirects to the index when the mix is missing", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/sets-online"}}} =
             live(conn, ~p"/sets-online/#{Ecto.UUID.generate()}")
  end

  test "editing a segment name persists and re-matches the library", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_artist: "Djavan",
        tag_title: "Sina",
        norm_artist: Normalize.normalize("Djavan"),
        norm_title: Normalize.normalize("Sina")
      )

    mix = insert(:mix, status: :ready)
    seg = insert(:mix_segment, mix: mix, position: 0, start_ms: 0, artist: nil, title: nil)

    {:ok, view, _html} = live(conn, ~p"/sets-online/#{mix.id}")

    view
    |> form("#seg-form-#{seg.id}", %{artist: "Djavan", title: "Sina"})
    |> render_submit()

    reloaded = Repo.get(Segment, seg.id)
    assert reloaded.artist == "Djavan" and reloaded.name_source == :manual
    assert reloaded.matched_track_id == track.id
  end

  test "Re-analisar re-enqueues the analyze worker", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/m.mp3")
    {:ok, view, _html} = live(conn, ~p"/sets-online/#{mix.id}")

    view |> element("button[phx-click=reanalyze]") |> render_click()
    assert_enqueued(worker: MixAnalyzeWorker, args: %{mix_id: mix.id})
  end

  test "renders DJ section headers when dj parts exist", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, title: "T1")
    insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ A", source: :manual)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "DJ A"
  end

  test "manual timestamps create dj sections", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000)

    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    render_submit(element(view, "#dj-manual-form"), %{"timestamps" => "0:00 A\n5:00 B"})
    assert render(view) =~ "A" and render(view) =~ "B"
  end

  test "shows live analysis progress", %{conn: conn} do
    mix = insert(:mix, status: :analyzing, duration_ms: 600_000)
    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    Beatgrid.Mixes.broadcast(%{mix_id: mix.id, stage: "segments", done: 12, total: 40})
    assert render(view) =~ "12/40"
  end

  test "format_clock renders a 3-hour mix as H:MM:SS, not as MM:SS", %{conn: conn} do
    # 10_800_000 ms = 3 h exactly; the old MM:SS code would render "180:00"
    mix = insert(:mix, status: :ready, duration_ms: 10_800_000)
    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "3:00:00"
    refute html =~ "180:00"
  end

  test "shows the player bar + per-segment play buttons when audio is present", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3", audio_deleted_at: nil)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 60_000)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ ~s(id="mix-audio")
    assert html =~ "/sets-online/#{mix.id}/audio"
    assert html =~ "data-seg-play"
    assert html =~ ~s(data-start-ms="0")
  end

  test "hides the player when the audio was purged", %{conn: conn} do
    mix =
      insert(:mix,
        status: :ready,
        audio_path: nil,
        audio_deleted_at: ~U[2026-06-29 00:00:00Z]
      )

    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 60_000)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    refute html =~ ~s(id="mix-audio")
    refute html =~ "data-seg-play"
    assert html =~ "Áudio apagado"
  end

  test "AudD recognize button + gate when no token", %{conn: conn} do
    original = Application.get_env(:beatgrid, Beatgrid.Recognition.Audd)

    on_exit(fn ->
      Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, original || [])
    end)

    Application.put_env(:beatgrid, Beatgrid.Recognition.Audd, api_token: nil)

    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 60_000, artist: nil, title: nil)

    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "Reconhecer faixas"
    assert html =~ "AUDD_API_TOKEN"
  end

  test "via-AudD tag on fingerprint segments", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")

    insert(:mix_segment,
      mix: mix,
      position: 0,
      start_ms: 0,
      end_ms: 60_000,
      artist: "X",
      title: "Y",
      name_source: :fingerprint
    )

    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "via AudD"
  end

  test "player preloads metadata and the segment time is clickable to seek", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3", audio_deleted_at: nil)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 90_000, end_ms: 180_000)
    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ ~s(preload="metadata")
    # the clock (mm:ss) carries data-seg-play so clicking it seeks
    assert html =~ "data-seg-play"
    assert html =~ ~s(data-start-ms="90000")
  end

  test "set summary cards show DJ count, tracks, duration and library coverage", %{conn: conn} do
    track = insert(:track, status: :present)
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 300_000, matched_track_id: track.id)
    insert(:mix_segment, mix: mix, position: 1, start_ms: 300_000, end_ms: 600_000)
    insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ A", source: :image)

    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ "Na biblioteca" and html =~ "50%"
    assert html =~ "DJ A" and html =~ "via OCR"
  end

  test "analyze_all button enqueues the free pipeline", %{conn: conn} do
    mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0, end_ms: 60_000)
    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    view |> element("button[phx-click=analyze_all]") |> render_click()
    assert_enqueued(worker: Beatgrid.Workers.MixAnalyzeWorker, args: %{mix_id: mix.id, free_djs: true})
  end

  test "rename a DJ divider inline", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    part = insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ VHSFNTG", source: :image)

    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    render_submit(element(view, "#dj-rename-#{part.id}"), %{"name" => "DJ VHANNY"})
    assert render(view) =~ "DJ VHANNY"
    refute render(view) =~ "DJ VHSFNTG"
  end

  test "delete a DJ divider", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    part = insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ X", source: :image)

    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
    view |> element("button[phx-click=delete_dj][phx-value-id=\"#{part.id}\"]") |> render_click()
    refute render(view) =~ "DJ X"
  end

  test "delete a DJ divider asks for confirmation first", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ X", source: :image)

    {:ok, _view, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ ~s(data-confirm="Apagar esta divisória?")
  end

  test "rename persists on change/blur, not only on Enter", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    part = insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ OLD", source: :image)

    {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

    render_change(element(view, "#dj-rename-#{part.id}"), %{"part_id" => part.id, "name" => "DJ NEW"})

    [reloaded] = Beatgrid.Mixes.get_with_dj_parts(mix.id).dj_parts
    assert reloaded.dj_name == "DJ NEW"
  end

  test "rename input carries an accessible label", %{conn: conn} do
    mix = insert(:mix, status: :ready, duration_ms: 600_000)
    insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
    insert(:dj_part, mix: mix, position: 0, start_ms: 0, end_ms: 600_000, dj_name: "DJ RATA", source: :image)

    {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
    assert html =~ ~s(aria-label="Renomear DJ: DJ RATA")
  end

  describe "audio lifecycle" do
    test "reanalyze with no audio shows an error and does not enqueue analysis", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: nil, audio_deleted_at: ~U[2026-06-30 00:00:00Z])
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      # drive the event directly: the handler must guard even if the (disabled) button is bypassed
      render_click(view, "reanalyze")

      refute_enqueued(worker: MixAnalyzeWorker)
      assert render(view) =~ "Áudio apagado"
    end

    test "reprocess buttons are disabled when the audio was deleted", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: nil, audio_deleted_at: ~U[2026-06-30 00:00:00Z])
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      assert has_element?(view, "button[phx-click=reanalyze][disabled]")
      assert has_element?(view, "button[phx-click=analyze_all][disabled]")
    end

    test "reprocess buttons are enabled when the audio is present", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3", audio_deleted_at: nil)
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      refute has_element?(view, "button[phx-click=reanalyze][disabled]")
      refute has_element?(view, "button[phx-click=analyze_all][disabled]")
    end

    test "delete_audio purges the file (confirmed) and keeps the analysis", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3", audio_deleted_at: nil)
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      {:ok, view, html} = live(conn, ~p"/sets-online/#{mix.id}")

      assert html =~ "data-confirm"
      assert has_element?(view, "button[phx-click=delete_audio]")

      render_click(view, "delete_audio")

      reloaded = Beatgrid.Mixes.get_mix(mix.id)
      assert reloaded.audio_path == nil
      assert reloaded.audio_deleted_at != nil
      # segments (analysis) preserved
      assert Beatgrid.Mixes.get_with_segments(mix.id).segments != []
    end

    test "shows 'baixar áudio de novo' when deleted and re-downloads restore-only", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: nil, audio_deleted_at: ~U[2026-06-30 00:00:00Z])
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      assert has_element?(view, "button[phx-click=redownload_audio]")
      render_click(view, "redownload_audio")

      assert_enqueued(
        worker: Beatgrid.Workers.MixDownloadWorker,
        args: %{mix_id: mix.id, restore_only: true}
      )
    end

    test "no re-download button while the audio is present", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3", audio_deleted_at: nil)
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
      refute has_element?(view, "button[phx-click=redownload_audio]")
    end
  end

  describe "recognition controls" do
    # AudD is configured by default in tests (config/test.exs); don't mutate that global
    # here — this module is async and would race other modules' gate tests.
    test "'Tentar tudo de novo' appears for already-tried no-match segments and forces a retry", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")

      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        artist: nil,
        title: nil,
        audd_attempted_at: ~U[2026-06-30 00:00:00Z]
      )

      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      assert has_element?(view, "button[phx-click=recognize_retry_all]")
      render_click(view, "recognize_retry_all")

      assert_enqueued(
        worker: Beatgrid.Workers.MixRecognizeWorker,
        args: %{mix_id: mix.id, retry_all: true}
      )
    end

    test "no 'Tentar tudo de novo' when nothing has been tried yet", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0, artist: nil, title: nil)
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")
      refute has_element?(view, "button[phx-click=recognize_retry_all]")
    end

    test "an unnamed segment AudD already tried shows a 'sem match' marker", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")

      insert(:mix_segment,
        mix: mix,
        position: 0,
        start_ms: 0,
        artist: nil,
        title: nil,
        audd_attempted_at: ~U[2026-06-30 00:00:00Z]
      )

      {:ok, _v, html} = live(conn, ~p"/sets-online/#{mix.id}")
      assert html =~ "sem match"
    end

    test "shows the recognition summary when the batch finishes", %{conn: conn} do
      mix = insert(:mix, status: :ready, audio_path: "/tmp/_Mixes/x.mp3")
      insert(:mix_segment, mix: mix, position: 0, start_ms: 0)
      {:ok, view, _} = live(conn, ~p"/sets-online/#{mix.id}")

      Beatgrid.Mixes.broadcast(%{
        mix_id: mix.id,
        stage: "recognize_done",
        matched: 3,
        no_match: 34,
        error: 0,
        total: 37
      })

      assert render(view) =~ "3 reconhecida"
      assert render(view) =~ "34 sem match"
    end
  end
end
