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
  alias Beatgrid.Mixes

  def show(conn, %{"id" => id}) do
    with %{rel_path: rel} <- Tracks.get(id),
         path = Path.join(Library.library_root(), rel),
         true <- within_root?(path) and File.exists?(path) do
      serve(conn, path)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  def mix(conn, %{"id" => id}) do
    with %{audio_path: path} when is_binary(path) <- Mixes.get_mix(id),
         true <- within_root?(path) and File.exists?(path) do
      serve(conn, path)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp within_root?(path) do
    root = Path.expand(Library.library_root())
    expanded = Path.expand(path)
    # Trailing-separator guard so a sibling dir sharing the prefix (".../lib-evil")
    # can't pass a bare String.starts_with? check.
    expanded == root or String.starts_with?(expanded, root <> "/")
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
        case parse_range(spec, size) do
          {:ok, offset, length} ->
            conn
            |> put_resp_header("content-range", "bytes #{offset}-#{offset + length - 1}/#{size}")
            |> send_file(206, path, offset, length)

          :unsatisfiable ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")

          :invalid ->
            send_file(conn, 200, path)
        end

      _ ->
        send_file(conn, 200, path)
    end
  end

  defp parse_range(spec, size) do
    spec =
      spec
      |> String.split(",", parts: 2)
      |> List.first()
      |> String.trim()

    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        suffix_range(parse_non_negative(suffix), size)

      [start, ""] ->
        open_range(parse_non_negative(start), size)

      [start, finish] ->
        closed_range(parse_non_negative(start), parse_non_negative(finish), size)

      _ ->
        :invalid
    end
  end

  defp parse_non_negative(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp suffix_range({:ok, suffix}, size) when suffix > 0 and size > 0 do
    offset = max(size - suffix, 0)
    {:ok, offset, size - offset}
  end

  defp suffix_range({:ok, _suffix}, _size), do: :unsatisfiable
  defp suffix_range(:error, _size), do: :invalid

  defp open_range({:ok, start}, size) when start < size and size > 0,
    do: {:ok, start, size - start}

  defp open_range({:ok, _start}, _size), do: :unsatisfiable
  defp open_range(:error, _size), do: :invalid

  defp closed_range({:ok, start}, {:ok, finish}, size)
       when start <= finish and start < size and size > 0 do
    finish = min(finish, size - 1)
    {:ok, start, finish - start + 1}
  end

  defp closed_range({:ok, _start}, {:ok, _finish}, _size), do: :unsatisfiable
  defp closed_range(_start, _finish, _size), do: :invalid
end
