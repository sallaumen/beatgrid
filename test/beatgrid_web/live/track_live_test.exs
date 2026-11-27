defmodule BeatgridWeb.TrackLiveTest do
  use BeatgridWeb.ConnCase, async: true, oban: true

  import Phoenix.LiveViewTest
  import Beatgrid.Factory

  alias Beatgrid.Analysis
  alias Beatgrid.Library.{Marker, Tracks}
  alias Beatgrid.Operations
  alias Beatgrid.Repertoire
  alias Beatgrid.Sets
  alias Beatgrid.Workers.{AnalyzeWorker, EnrichWorker, ExpandWorker, RecommendWorker}

  test "shows the detail and updates rating, tags and note", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        soundcharts_song: build(:soundcharts_song, camelot: "8A", tempo_bpm: 120.0, energy: 0.6),
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Sina"
    assert html =~ "Metadados"

    assert has_element?(
             view,
             "a[href='/manutencao#maintenance-loudness']",
             "Medir loudness em Manutenção"
           )

    view |> element(~s|button[phx-value-n="7"]|) |> render_click()
    assert Tracks.get(track.id).rating == 7

    view |> form("form[phx-submit=add_tag]", %{tag: "festa"}) |> render_submit()
    assert "festa" in Tracks.get(track.id).tags

    view |> element(~s|button[phx-value-tag="festa"]|) |> render_click()
    refute "festa" in Tracks.get(track.id).tags

    view |> form("form[phx-change=save_note]", %{note: "abertura"}) |> render_change()
    assert Tracks.get(track.id).personal_note == "abertura"
  end

  test "preparation and reference links reach every section, with editing before volume", %{
    conn: conn
  } do
    track = insert(:track, status: :present, analyzed_at: ~U[2026-01-01 00:00:00Z])
    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")

    sections = [
      {"track-edit", "Editar faixa"},
      {"track-curation", "Nota e tags"},
      {"track-markers", "Marcadores"},
      {"track-loudness", "Volume"},
      {"track-analysis", "Análise"},
      {"track-origin", "Origem"},
      {"track-versions", "Versões"},
      {"track-next", "Próxima faixa"},
      {"track-matches", "Parecidas (IA)"}
    ]

    offsets =
      for {id, label} <- sections do
        assert has_element?(view, "nav[aria-label='Seções da ficha'] a[href='##{id}']", label)
        assert has_element?(view, "section##{id}")
        {offset, _length} = :binary.match(html, ~s(id="#{id}"))
        offset
      end

    assert offsets == Enum.sort(offsets)

    view |> element("#track-edit button[aria-label='Editar Título']") |> render_click()

    view
    |> form("#track-edit form[phx-submit=save_field]", %{value: "Nome corrigido"})
    |> render_submit()

    assert has_element?(view, "h1", "Nome corrigido")

    view |> element("#track-curation button[phx-value-n='8']") |> render_click()
    view |> form("#track-curation #track-add-tag", %{tag: "abertura"}) |> render_submit()
    view |> form("#track-curation #track-note", %{note: "Usar na abertura"}) |> render_change()
    updated = Tracks.get(track.id)
    assert updated.rating == 8
    assert "abertura" in updated.tags
    assert updated.personal_note == "Usar na abertura"
    assert has_element?(view, "#track-add-marker[disabled]")
  end

  test "offers recovery for the current missing file", %{conn: conn} do
    track = insert(:track, status: :present, integrity_status: :missing_file)
    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    assert has_element?(
             view,
             "a[href='/resgate#arquivo-#{track.id}']",
             "Ver recuperação do arquivo"
           )

    refute has_element?(view, "button#play-track")
  end

  test "restoring a track backup does not undo other tracks from the batch", %{conn: conn} do
    batch_id = Ecto.UUID.generate()

    [track, other] =
      for _ <- 1..2 do
        track = insert(:track, status: :present)

        {:ok, _operation} =
          Operations.record(%{
            track_id: track.id,
            kind: :gain,
            status: :applied,
            from: "-4.2",
            to: "_Backups/Gain/#{batch_id}/#{track.id}.mp3",
            batch_id: batch_id
          })

        track
      end

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    view |> element("button[phx-click=restore_gain_backup]") |> render_click()

    assert Operations.latest_gain_operation(other.id).status == :applied
    assert render(view) =~ "Não foi possível restaurar o backup"
  end

  test "shows original and current loudness plus backup availability", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Normalized",
        loudness_lufs: -14.1,
        true_peak_dbtp: -3.8,
        loudness_attempted_at: ~U[2026-01-01 00:00:10Z],
        original_loudness_lufs: -9.8,
        original_true_peak_dbtp: -0.4,
        original_loudness_measured_at: ~U[2026-01-01 00:00:00Z],
        loudness_measurement_origin: :post_gain,
        gain_applied_db: -4.2,
        gain_applied_at: ~U[2026-01-01 00:01:00Z]
      )

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")

    assert html =~ "Backup original"
    assert html =~ "-9.8 LUFS"
    assert html =~ "-0.4 dBTP"
    assert html =~ "Arquivo atual"
    assert html =~ "-14.1 LUFS"
    assert html =~ "-3.8 dBTP"
    assert html =~ "Ganho aplicado"
    assert html =~ "-4.2 dB"
    assert html =~ "Sem backup original registrado"
    assert html =~ "Ganho recomendado"
  end

  test "the ficha titles identify the editing and marker sections and explain the disabled marker control",
       %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Uma faixa com nome longo que precisa caber inteiro",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    assert has_element?(view, "h1", track.tag_title)
    assert has_element?(view, "h2", "Editar faixa")
    assert has_element?(view, "h2", "Marcadores")

    assert has_element?(
             view,
             "#track-add-marker[disabled][aria-describedby='track-add-marker-help']"
           )

    assert has_element?(view, "#track-add-marker-help", "Toque esta faixa no player desta aba")
    assert has_element?(view, "#track-versions", "Nenhuma outra versão encontrada.")
  end

  test "inline-edits a metadata field and a manual BPM override", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Velho",
        soundcharts_song: build(:soundcharts_song, tempo_bpm: 120.0),
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "Editar faixa"

    view
    |> element(~s|button[phx-value-field=title][aria-label="Editar Título"]|)
    |> render_click()

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

    assert html =~ "Outras versões desta música"
    assert html =~ "Asa Branca (Ao Vivo)"
    assert html =~ "ao vivo"
  end

  test "shows a compact comparison cockpit with original-backup playback and playable versions",
       %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_artist: "Luiz Gonzaga",
        tag_title: "Asa Branca",
        norm_artist: "luiz gonzaga",
        norm_title: "asa branca",
        content_sha256: "original",
        loudness_lufs: -14.1,
        true_peak_dbtp: -3.8,
        original_loudness_lufs: -9.8,
        original_true_peak_dbtp: -0.4,
        gain_applied_db: -4.2,
        gain_applied_at: ~U[2026-01-01 00:01:00Z],
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    version =
      insert(:track,
        status: :present,
        tag_artist: "Dominguinhos",
        tag_title: "Asa Branca (Ao Vivo)",
        norm_artist: "dominguinhos",
        norm_title: "asa branca ao vivo",
        content_sha256: "version",
        loudness_lufs: -13.7,
        bpm_detected: 126.0,
        camelot_detected: "8A"
      )

    {:ok, _operation} =
      Operations.record(%{
        track_id: track.id,
        kind: :gain,
        status: :applied,
        from: "-4.2",
        to: "_Backups/Gain/batch/_Inbox/asa-branca.mp3",
        batch_id: Ecto.UUID.generate()
      })

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")

    assert html =~ "Backup original"
    assert html =~ "-9.8 LUFS"
    assert html =~ "Arquivo atual"
    assert html =~ "-14.1 LUFS"
    assert html =~ "Backup original registrado"
    assert has_element?(view, "button", "Tocar original")
    assert has_element?(view, "button", "Restaurar backup original")
    assert html =~ ~p"/audio/#{track.id}/original"
    assert html =~ "Outras versões desta música"
    assert has_element?(view, "a[href='/track/#{version.id}']", "Asa Branca (Ao Vivo)")
    assert html =~ ~p"/audio/#{version.id}"
    refute html =~ "Start set"
  end

  test "hands this exact recording to the set planner without creating a set", %{conn: conn} do
    track = insert(:track, status: :present)
    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    assert has_element?(
             view,
             "#track-use-in-set[href='/set?track_id=#{track.id}']",
             "Usar em um set"
           )

    refute has_element?(view, "button[phx-click=start_set]")
    assert Sets.list() == []
  end

  test "returns to the originating set and keeps the recording when adding from that set", %{
    conn: conn
  } do
    track = insert(:track, status: :present)
    {:ok, set} = Sets.create("Baile de sexta")
    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}?set_id=#{set.id}")

    assert has_element?(view, "#track-return[href='/set/#{set.id}']", "Baile de sexta")
    assert has_element?(view, "#track-use-in-set[href='/set/#{set.id}?track_id=#{track.id}']")
    assert Sets.entries(set) == []

    {:ok, _} = Sets.append(set, track)
    {:ok, member, _} = live(conn, ~p"/track/#{track.id}?set_id=#{set.id}")

    assert has_element?(
             member,
             "#track-use-in-set[href='/set?track_id=#{track.id}']",
             "Usar em outro set"
           )

    for invalid <- ["desconhecido", Ecto.UUID.generate()] do
      {:ok, fallback, _} = live(conn, ~p"/track/#{track.id}?set_id=#{invalid}")
      assert has_element?(fallback, "#track-return[href='/']", "Biblioteca")
    end
  end

  test "the track sheet restores the library view and ignores foreign return destinations", %{
    conn: conn
  } do
    track = insert(:track, status: :present)
    path = ~p"/?search=Sina"
    {:ok, view, _} = live(conn, ~p"/track/#{track.id}?library=#{path}")
    assert has_element?(view, "#track-return[href='#{path}']", "Biblioteca")

    for dest <- ["//example.org", "/ajustes", "https://example.org/?search=Sina"] do
      {:ok, safe, _} = live(conn, ~p"/track/#{track.id}?library=#{dest}")
      assert has_element?(safe, "#track-return[href='/']")
    end

    assert {:error, {:live_redirect, %{to: ^path}}} =
             live(conn, ~p"/track/invalid?library=#{path}")
  end

  test "a missing recording directs the DJ to recovery before performing or planning", %{
    conn: conn
  } do
    track = insert(:track, status: :missing, integrity_status: nil)
    {:ok, view, _} = live(conn, ~p"/track/#{track.id}")

    assert has_element?(view, "a[href='/resgate#arquivo-#{track.id}']", "Ver recuperação")
    refute has_element?(view, "#track-use-in-set")
    refute has_element?(view, "#play-track")
  end

  test "uses the unified player and renders manageable markers", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "X",
        tag_artist: "Y",
        cue_points: [%{"ms" => 30_000, "label" => nil}],
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")

    # No more track-local waveform — playback goes through the global player.
    refute html =~ "track-waveform"
    refute html =~ ~s(phx-hook="Waveform")
    # Prominent play button dispatches to the shared #player-audio.
    assert html =~ "beatgrid:play"
    assert html =~ "player-audio"
    send(view.pid, {:now_playing, %{track_id: track.id}})

    assert has_element?(
             view,
             "button[title='Tocar no player global'][phx-click*='toggle_if_current'][phx-click*='#{track.id}']"
           )

    assert has_element?(
             view,
             "#track-add-marker[data-track-id='#{track.id}'][phx-click*='track_id'][phx-click*='#{track.id}'][disabled]"
           )

    # A global now-playing broadcast cannot enable a marker control in a different
    # tab. The local player hook re-syncs the button once it can mark a position.
    assert has_element?(view, "#track-add-marker-help")

    # Marker section shows the existing cue at 0:30.
    assert html =~ "Marcadores"
    assert html =~ "0:30"

    # Rename it inline (the marker_list form submits rename_marker).
    render_hook(view, "rename_marker", %{"ms" => "30000", "label" => "drop"})
    assert [%{"ms" => 30_000, "label" => "drop"}] = Tracks.get(track.id).cue_points
    assert render(view) =~ "drop"

    view |> element("button[phx-click=remove_marker][phx-value-ms='30000']") |> render_click()
    assert Tracks.get(track.id).cue_points == []
  end

  test "a markers_changed broadcast reloads this track's markers", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "X", tag_artist: "Y")
    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    refute render(view) =~ "1:00"

    # A marker added elsewhere (e.g. from the player) → the page refreshes on the broadcast.
    {:ok, _} = Tracks.add_marker(track, 60_000, "refrão")
    send(view.pid, {:markers_changed, track.id})

    html = render(view)
    assert html =~ "1:00"
    assert html =~ "refrão"
  end

  test "marker list colors by type and can change a marker's type", %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "T",
        tag_artist: "A",
        cue_points: [%{"ms" => 30_000, "label" => nil, "type" => "cue", "source" => "manual"}],
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    {:ok, view, html} = live(conn, ~p"/track/#{track.id}")
    assert html =~ "#ffb020"

    render_hook(view, "set_marker_type", %{"ms" => "30000", "type" => "intro"})
    assert [marker] = Tracks.get(track.id).cue_points
    assert Marker.type(marker) == "intro"
    assert render(view) =~ "#5ad1a0"
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
    assert html =~ "Reanalisar áudio local"
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

  test "a suggested match opens a version review without importing", %{conn: conn} do
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
    assert has_element?(view, "a[href='/importados?recomendacao=#{rec.id}']", "Conferir versões")
    refute_enqueued(worker: ExpandWorker)
    assert Repertoire.get_recommendation(rec.id).status == :new
  end

  test "imported matches are history with the same options, not a link to the reference track", %{
    conn: conn
  } do
    track = insert(:track, status: :present, tag_title: "Sina", tag_artist: "Djavan")

    pending =
      insert(:recommendation,
        track_id: track.id,
        genre_folder: nil,
        source: :match,
        status: :new,
        song: "Faixa pendente"
      )

    imported =
      insert(:recommendation,
        track_id: track.id,
        genre_folder: nil,
        source: :match,
        status: :imported,
        song: "Faixa importada"
      )

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")
    pending_row = "#track-matches-pending #recommendation-#{pending.id}"
    history_row = "#track-matches-imported #recommendation-#{imported.id}"

    assert has_element?(
             view,
             "#{pending_row} > [data-recommendation-actions] > a:first-child[href='/importados?recomendacao=#{pending.id}']",
             "Conferir versões"
           )

    assert has_element?(view, "#track-matches-imported:not([open]) > summary", "Já importadas")
    assert has_element?(view, history_row, "Importada")

    assert has_element?(
             view,
             "#{history_row} details:not([open]) > summary",
             "Opções da sugestão"
           )

    refute has_element?(view, "#{history_row} a[href='/track/#{track.id}']")
    assert has_element?(view, "#{history_row} details a[target=_blank]", "Buscar no YouTube")

    assert has_element?(
             view,
             "#{history_row} details a[href='/importados?recomendacao=#{imported.id}']"
           )

    view |> element("#{history_row} details button[phx-click=dismiss_rec]") |> render_click()
    assert Repertoire.get_recommendation(imported.id).status == :dismissed
    refute has_element?(view, history_row)
    assert has_element?(view, pending_row)
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

  test "enrich button shows the soundcharts gate when no credentials are configured",
       %{conn: conn} do
    track =
      insert(:track,
        status: :present,
        tag_title: "Sina",
        tag_artist: "Djavan",
        analyzed_at: ~U[2026-01-01 00:00:00Z]
      )

    # Temporarily strip Soundcharts credentials so the gate renders.
    original = Application.get_env(:beatgrid, Beatgrid.Soundcharts.Http, [])

    Application.put_env(
      :beatgrid,
      Beatgrid.Soundcharts.Http,
      Keyword.put(original, :accounts, [])
    )

    on_exit(fn -> Application.put_env(:beatgrid, Beatgrid.Soundcharts.Http, original) end)

    {:ok, _view, html} = live(conn, ~p"/track/#{track.id}")
    # Gate hint appears when Soundcharts is not configured.
    assert html =~ "SOUNDCHARTS_APP_ID"
  end

  test "the Ouro badge is clickable and toggles the manual gold override", %{conn: conn} do
    track = insert(:track, status: :present, tag_title: "Rara", tag_artist: "X")
    # a bare track is not automatically gold
    assert {false, _} = Beatgrid.Gold.effective(track)

    {:ok, view, _html} = live(conn, ~p"/track/#{track.id}")

    # a clickable Ouro control exists even when the track is NOT gold yet (so it can be added)
    assert has_element?(view, "button[phx-click=toggle_gold][aria-pressed=false]", "Ouro")

    # one click flags it as Ouro (manual override) — a personally-rare track
    view |> element("button[phx-click=toggle_gold]") |> render_click()
    reloaded = Tracks.get(track.id)
    refute is_nil(reloaded.gold_manual)
    assert {true, _} = Beatgrid.Gold.effective(reloaded)
    assert has_element?(view, "button[phx-click=toggle_gold][aria-pressed=true]", "Ouro")

    # clicking again reverts to automatic
    view |> element("button[phx-click=toggle_gold]") |> render_click()
    assert is_nil(Tracks.get(track.id).gold_manual)
  end
end
