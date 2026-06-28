defmodule BeatgridWeb.TrackLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Analysis
  alias Beatgrid.Library.Tracks
  alias Beatgrid.Repertoire
  alias Beatgrid.Workers.{AnalyzeWorker, EnrichWorker, ExpandWorker, RecommendWorker}

  test "shows the detail and updates rating, tags and note", %{conn: conn} do
    song = insert(:soundcharts_song, camelot: "8A", tempo_bpm: 120.0, energy: 0.6)

    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        soundcharts_song_id: song.id,
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Sina"
    assert html =~ "Metadados"

    view |> element(~s|button[phx-value-n="7"]|) |> render_click()
    assert Tracks.get(track.id).rating == 7

    view |> form("form[phx-submit=add_tag]", %{tag: "festa"}) |> render_submit()
    assert "festa" in Tracks.get(track.id).tags

    view |> element(~s|button[phx-value-tag="festa"]|) |> render_click()
    refute "festa" in Tracks.get(track.id).tags

    view |> form("form[phx-change=save_note]", %{note: "abertura"}) |> render_change()
    assert Tracks.get(track.id).personal_note == "abertura"
  end

  test "inline-edits a metadata field and a manual BPM override", %{conn: conn} do
    song = insert(:soundcharts_song, tempo_bpm: 120.0)

    track =
      insert(:track,
        status: :present,
        tag_title: "Velho",
        soundcharts_song_id: song.id,
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Dados (editáveis)"

    # Edit the title inline (pencil → form → submit).
    view |> element(~s|button[phx-click=edit_field][phx-value-field=title]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "Novo Nome"}) |> render_submit()
    t = Tracks.get(track.id)
    assert t.tag_title == "Novo Nome"
    assert "title" in t.manual_fields

    # Manual BPM override wins over the Soundcharts 120.
    view |> element(~s|button[phx-click=edit_field][phx-value-field=bpm]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "128"}) |> render_submit()
    assert Tracks.get(track.id).bpm_manual == 128.0
    assert render(view) =~ "128"

    # Clearing the BPM reverts to the automatic value.
    view |> element(~s|button[phx-click=edit_field][phx-value-field=bpm]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: ""}) |> render_submit()
    assert Tracks.get(track.id).bpm_manual == nil
  end

  test "an invalid year is ignored instead of wiping the existing one", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "X",
        tag_year: 1998,
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view |> element(~s|button[phx-click=edit_field][phx-value-field=year]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "19xx"}) |> render_submit()

    # Garbage must NOT clear a good year.
    assert Tracks.get(track.id).tag_year == 1998
  end

  test "re-submitting an unchanged metadata value does not mark it edited", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    view |> element(~s|button[phx-click=edit_field][phx-value-field=title]|) |> render_click()
    view |> form("form[phx-submit=save_field]", %{value: "Sina"}) |> render_submit()

    refute "title" in Tracks.get(track.id).manual_fields
  end

  test "an unknown edit_field is ignored and does not crash the LiveView", %{conn: conn} do
    track =
      insert(:track, status: :present, tag_title: "X", analyzed_at: ~U[2026-01-01 00:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    # phx-value-field is client-controlled; a crafted value must not raise.
    assert render_hook(view, "edit_field", %{"field" => "totally_unknown_xyz"})
    assert Process.alive?(view.pid)
  end

  test "Apagar removes the track and navigates back to the library", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Errada",
        tag_artist: "X",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=delete_track]") |> render_click()

    assert_redirect(view, ~p"/")
    assert Tracks.get(track.id) == nil
  end

  test "lists other versions of the same song", %{conn: conn} do
    studio =
      insert(:track,
        status: :present,
        tag_artist: "Gonzaga",
        tag_title: "Asa Branca",
        norm_artist: "gonzaga",
        norm_title: "asa branca",
        content_sha256: "a",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    insert(:track,
      status: :present,
      tag_artist: "Gonzaga",
      tag_title: "Asa Branca (Ao Vivo)",
      norm_artist: "gonzaga",
      norm_title: "asa branca ao vivo",
      content_sha256: "b"
    )

    {:ok, _view, html} = live(conn, ~p"/track/#{studio.id}")

    assert html =~ "Outras versões"
    assert html =~ "Asa Branca (Ao Vivo)"
    assert html =~ "ao vivo"
  end

  test "starts a set seeded with this track and navigates to /set", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=start_set]") |> render_click()

    assert_redirect(view, ~p"/set")
    assert [set] = Beatgrid.Sets.list()
    assert Enum.map(Beatgrid.Sets.tracks(set), & &1.id) == [track.id]
  end

  test "renders the waveform player and adds/removes a marker", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "X",
        tag_artist: "Y",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "track-waveform"
    assert html =~ ~s(phx-hook="Waveform")

    render_hook(view, "add_marker", %{"ms" => 30_000})
    assert [%{"ms" => 30_000}] = Tracks.get(track.id).cue_points
    assert render(view) =~ "0:30"

    view |> element("button[phx-click=remove_marker][phx-value-ms='30000']") |> render_click()
    assert Tracks.get(track.id).cue_points == []
  end

  test "redirects to the library when the track is not found", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/track/#{Ecto.UUID.generate()}")
  end

  test "renders the Atualizar metadados button with data-confirm", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Atualizar metadados"
    assert html =~ "phx-click=\"enrich_track\""
    assert html =~ "data-confirm"
  end

  test "shows YouTube video and playlist links when raw_tags present", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Disritmia",
        tag_artist: "Casuarina",
        analyzed_at: ~U[2026-01-01 00:00:00Z],
        raw_tags: %{
          "youtube_url" => "https://youtu.be/abc123",
          "youtube_playlist_url" => "https://youtube.com/playlist?list=PL1"
        }
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "https://youtu.be/abc123"
    assert html =~ "https://youtube.com/playlist?list=PL1"
    assert html =~ "Abrir vídeo"
    assert html =~ "Abrir playlist"
  end

  test "does not show YouTube rows when raw_tags has no youtube keys", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z],
        raw_tags: %{}
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    refute html =~ "Abrir vídeo"
    refute html =~ "Abrir playlist"
  end

  test "opening an unanalyzed track enqueues an AnalyzeWorker job", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    {:ok, _view, _html} = live(conn, ~p"/track/#{track.id}")

    assert_enqueued(worker: AnalyzeWorker, args: %{track_id: track.id})
  end

  test "opening an already-analyzed track does not enqueue analysis", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, _view, _html} = live(conn, ~p"/track/#{track.id}")

    refute_enqueued(worker: AnalyzeWorker)
  end

  test "clicking Re-analisar enqueues an AnalyzeWorker job", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    refute_enqueued(worker: AnalyzeWorker)

    view |> element("button[phx-click=reanalyze]") |> render_click()

    assert_enqueued(worker: AnalyzeWorker, args: %{track_id: track.id})
  end

  test "an analysis tick after the track is analyzed clears analyzing? and shows BPM",
       %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    # Auto-analysis enqueued → the analyzing placeholder is rendered.
    assert html =~ "Analisando…"

    # Simulate the worker finishing: the track now has BPM + analyzed_at, then a tick.
    {:ok, _} =
      Tracks.update(track, %{bpm_detected: 128.0, analyzed_at: ~U[2026-01-02 00:00:00Z]})

    Analysis.broadcast_tick()

    html = render(view)
    assert html =~ "Re-analisar"
    refute html =~ "Analisando…"
    assert html =~ "128"
  end

  test "clicking Atualizar metadados enqueues an EnrichWorker track job", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=enrich_track]") |> render_click()

    assert_enqueued(worker: EnrichWorker, args: %{scope: "track", id: track.id})
    assert render(view) =~ "Atualizando…"
  end

  test "an enrich :done event for this track clears enriching? and toasts", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=enrich_track]") |> render_click()
    assert render(view) =~ "Atualizando…"

    send(
      view.pid,
      {:enrich_progress,
       %{
         scope: "track",
         id: track.id,
         status: :done,
         done: 1,
         total: 1,
         resolved: 1,
         budget_exhausted: false
       }}
    )

    html = render(view)
    refute html =~ "Atualizando…"
    assert html =~ "Metadados atualizados"
  end

  test "an enrich :done event for another track is ignored", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=enrich_track]") |> render_click()
    assert render(view) =~ "Atualizando…"

    # Progress for a different track id must not clear this view's state.
    send(
      view.pid,
      {:enrich_progress,
       %{
         scope: "track",
         id: Ecto.UUID.generate(),
         status: :done,
         done: 1,
         total: 1,
         resolved: 1,
         budget_exhausted: false
       }}
    )

    assert render(view) =~ "Atualizando…"
  end

  test "renders persisted similar suggestions for the track on mount", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    insert(:recommendation,
      artist: "Gilberto Gil",
      song: "Aquele Abraço",
      reason: "mesma época",
      track_id: track.id,
      genre_folder: nil,
      source: :match,
      status: :new
    )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")

    assert html =~ "Sugestões parecidas (IA)"
    assert html =~ "Gilberto Gil"
    assert html =~ "Aquele Abraço"
    assert html =~ "mesma época"
  end

  test "clicking Buscar parecidas enqueues a track RecommendWorker", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    html = view |> element("button[phx-click=fetch_matches]") |> render_click()

    assert_enqueued(worker: RecommendWorker, args: %{scope: "track", track_id: track.id})
    assert html =~ "Gerando…"
  end

  test "a recommend-progress :done event for this track renders persisted matches", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    refute render(view) =~ "Caetano Veloso"

    insert(:recommendation,
      artist: "Caetano Veloso",
      song: "Sozinho",
      reason: "vibe parecida",
      track_id: track.id,
      genre_folder: nil,
      source: :match,
      status: :new
    )

    send(
      view.pid,
      {:recommend_progress,
       %{batch_id: "b1", scope: "track", key: track.id, status: :done, count: 1}}
    )

    assert render(view) =~ "Caetano Veloso"
  end

  test "a recommend-progress :done event for another track is ignored", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    insert(:recommendation,
      artist: "Caetano Veloso",
      song: "Sozinho",
      track_id: track.id,
      genre_folder: nil,
      source: :match,
      status: :new
    )

    # A tick for a different track must not reload this view's suggestions.
    send(
      view.pid,
      {:recommend_progress,
       %{batch_id: "b1", scope: "track", key: Ecto.UUID.generate(), status: :done, count: 1}}
    )

    refute render(view) =~ "Caetano Veloso"
  end

  test "Baixar on a match enqueues a YouTube download and marks it imported", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    rec =
      insert(:recommendation,
        artist: "Tim Maia",
        song: "Azul da Cor do Mar",
        youtube_query: "Tim Maia Azul da Cor do Mar",
        track_id: track.id,
        genre_folder: nil,
        source: :match,
        status: :new
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=download_rec][phx-value-id='#{rec.id}']") |> render_click()

    assert_enqueued(worker: ExpandWorker)
    assert Repertoire.get_recommendation(rec.id).status == :imported
    assert render(view) =~ "baixada"
  end

  test "Dispensar on a match hides it and marks it dismissed", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    rec =
      insert(:recommendation,
        artist: "Cartola",
        song: "O Mundo é um Moinho",
        track_id: track.id,
        genre_folder: nil,
        source: :match,
        status: :new
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    assert render(view) =~ "Cartola"

    view |> element("button[phx-click=dismiss_rec][phx-value-id='#{rec.id}']") |> render_click()

    html = render(view)
    refute html =~ "Cartola"
    assert Repertoire.get_recommendation(rec.id).status == :dismissed
  end

  test "shows the Ouro badge for a gold track", %{conn: conn} do
    track = insert(:track, status: :present, gold_status: :confirmed, tag_title: "Pérola")

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Ouro — não está no Soundcharts"
  end

  test "marks the page as playing when it is the now-playing track", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    # Another track playing → this page is not marked.
    send(view.pid, {:now_playing, %{track_id: Ecto.UUID.generate(), set_id: nil}})
    refute render(view) =~ "Tocando agora"

    # This track becomes the now-playing one → the page lights up.
    send(view.pid, {:now_playing, %{track_id: track.id, set_id: nil}})
    assert render(view) =~ "Tocando agora"
  end
end
