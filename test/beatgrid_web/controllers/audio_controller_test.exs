defmodule BeatgridWeb.AudioControllerTest do
  # async: false — overrides :library_root and reads files from disk.
  use BeatgridWeb.ConnCase, async: false

  import Beatgrid.Factory

  setup tags do
    if root = tags[:tmp_dir] do
      prev = Application.get_env(:beatgrid, :library_root)
      Application.put_env(:beatgrid, :library_root, root)
      on_exit(fn -> Application.put_env(:beatgrid, :library_root, prev) end)
    end

    :ok
  end

  @tag :tmp_dir
  test "serves the track's audio file, full and by range", %{conn: conn, tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "MPB"))
    File.write!(Path.join(root, "MPB/song.mp3"), "0123456789")
    track = insert(:track, rel_path: "MPB/song.mp3", filename: "song.mp3")

    full = get(conn, ~p"/audio/#{track.id}")
    assert full.status == 200
    assert get_resp_header(full, "content-type") == ["audio/mpeg"]
    assert get_resp_header(full, "accept-ranges") == ["bytes"]
    assert full.resp_body == "0123456789"

    ranged = conn |> put_req_header("range", "bytes=2-5") |> get(~p"/audio/#{track.id}")
    assert ranged.status == 206
    assert get_resp_header(ranged, "content-range") == ["bytes 2-5/10"]
    assert ranged.resp_body == "2345"
  end

  test "404 when the track does not exist", %{conn: conn} do
    assert get(conn, ~p"/audio/#{Ecto.UUID.generate()}").status == 404
  end

  @tag :tmp_dir
  test "404 when the file is missing on disk", %{conn: conn} do
    track = insert(:track, rel_path: "MPB/gone.mp3", filename: "gone.mp3")
    assert get(conn, ~p"/audio/#{track.id}").status == 404
  end

  @tag :tmp_dir
  test "serves the mix audio file, full and by range", %{conn: conn, tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "_Mixes"))
    path = Path.join(root, "_Mixes/abc.mp3")
    File.write!(path, "0123456789")
    mix = insert(:mix, audio_path: path)

    full = get(conn, ~p"/sets-online/#{mix.id}/audio")
    assert full.status == 200
    assert get_resp_header(full, "accept-ranges") == ["bytes"]
    assert full.resp_body == "0123456789"

    ranged = conn |> put_req_header("range", "bytes=2-5") |> get(~p"/sets-online/#{mix.id}/audio")
    assert ranged.status == 206
    assert get_resp_header(ranged, "content-range") == ["bytes 2-5/10"]
    assert ranged.resp_body == "2345"
  end

  test "404 when the mix has no audio", %{conn: conn} do
    mix = insert(:mix, audio_path: nil)
    assert get(conn, ~p"/sets-online/#{mix.id}/audio").status == 404
  end

  test "404 when the mix does not exist", %{conn: conn} do
    assert get(conn, ~p"/sets-online/#{Ecto.UUID.generate()}/audio").status == 404
  end
end
