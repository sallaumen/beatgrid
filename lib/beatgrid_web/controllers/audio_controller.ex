defmodule BeatgridWeb.AudioController do
  @moduledoc """
  Streams a track's audio file from the library root so the review UI can preview
  it in the browser. Supports HTTP Range requests (206) so the player can seek
  (e.g. skip the first 20 seconds) without downloading the whole file.
  """
  use BeatgridWeb, :controller

  # Sobelow reads @sobelow_skip from the AST; persist it so the Elixir compiler
  # doesn't warn it's an "unused" module attribute.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  alias Beatgrid.Library
  alias Beatgrid.Library.Tracks

  def show(conn, %{"id" => id}) do
    with %{rel_path: rel} <- Tracks.get(id),
         path = Path.join(Library.library_root(), rel),
         true <- within_root?(path) and File.exists?(path) do
      serve(conn, path)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp within_root?(path) do
    String.starts_with?(Path.expand(path), Path.expand(Library.library_root()))
  end

  # Reviewed false-positives: `path` is `library_root <> track.rel_path` (DB data,
  # not request input) and is fenced by `within_root?/1`; the content type is a
  # known MIME derived from that path. Safe to serve.
  @sobelow_skip ["Traversal.SendFile", "XSS.ContentType"]
  defp serve(conn, path) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_content_type(MIME.from_path(path), nil)
      |> put_resp_header("accept-ranges", "bytes")

    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        {offset, length} = clamp(parse_range(spec, size), size)

        conn
        |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{size}")
        |> send_file(206, path, offset, length)

      _ ->
        send_file(conn, 200, path)
    end
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-") do
      [start, ""] ->
        {String.to_integer(start), size - String.to_integer(start)}

      [start, finish] ->
        {String.to_integer(start), String.to_integer(finish) - String.to_integer(start) + 1}

      _ ->
        {0, size}
    end
  rescue
    _ -> {0, size}
  end

  defp clamp({offset, length}, size) do
    offset = offset |> max(0) |> min(size - 1)
    {offset, length |> max(1) |> min(size - offset)}
  end
end
