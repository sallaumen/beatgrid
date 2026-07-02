defmodule Beatgrid.Recognition.Audd do
  @moduledoc """
  `Recognition` adapter via AudD (https://audd.io). Extracts a ~20s snippet from the
  STABLE MIDDLE of the segment with ffmpeg and uploads it — the middle avoids the
  intro/outro transitions (and DJ blends) that confuse fingerprinting. Paid — only from a button.
  """
  @behaviour Beatgrid.Recognition

  alias Beatgrid.Cli
  alias Beatgrid.Error

  @endpoint "https://api.audd.io/"
  @snippet_ms 20_000
  # Cutting a ~20s snippet is quick; a minute covers slow disks and long seeks.
  @snippet_timeout_ms 60_000
  # Upload + fingerprinting round-trip; Req's default 15s is too tight for it.
  @receive_timeout_ms 30_000

  @impl true
  def identify(audio_path, start_ms, end_ms) do
    case token() do
      t when is_binary(t) and t != "" ->
        with_snippet(audio_path, start_ms, end_ms, fn snippet -> post(snippet, t) end)

      _ ->
        {:error, :no_credentials}
    end
  end

  @doc "The ~20s window to fingerprint: centered on the segment's midpoint, clamped to the segment."
  @spec snippet_window(integer(), integer()) :: {integer(), integer()}
  def snippet_window(start_ms, end_ms) do
    mid = div(start_ms + end_ms, 2)
    offset = max(start_ms, mid - div(@snippet_ms, 2))
    dur = max(1_000, min(@snippet_ms, end_ms - offset))
    {offset, dur}
  end

  defp with_snippet(audio_path, start_ms, end_ms, fun) do
    {offset, dur} = snippet_window(start_ms, end_ms)
    dest = Path.join(System.tmp_dir!(), "audd-#{System.unique_integer([:positive])}.mp3")

    args = [
      "-nostdin",
      "-ss",
      "#{offset / 1000}",
      "-t",
      "#{dur / 1000}",
      "-i",
      audio_path,
      "-ac",
      "1",
      "-y",
      dest
    ]

    try do
      cmd = fn -> System.cmd(ffmpeg(), args, stderr_to_stdout: true) end

      case Cli.run(cmd, @snippet_timeout_ms) do
        {:ok, {_out, 0}} ->
          fun.(dest)

        {:ok, {out, code}} ->
          {:error,
           Error.new(:ffmpeg_exit, "ffmpeg failed cutting the snippet", %{
             exit: code,
             output: String.slice(out, -300..-1//1)
           })}

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(dest)
    end
  end

  # NOTE (manual-verify): Req 0.5 `form_multipart` file-part shape verified via hexdocs:
  # `{binary, filename: "name.ext", content_type: "mime/type"}` is the documented form.
  # AudD expects multipart fields `api_token` + `file`. Validate against the real AudD
  # API before shipping the controller (the file part is not covered by unit tests here).
  defp post(snippet, tok) do
    case File.read(snippet) do
      {:ok, bytes} ->
        file_part = {bytes, filename: "snippet.mp3", content_type: "audio/mpeg"}

        case Req.post(@endpoint,
               form_multipart: [api_token: tok, file: file_part],
               receive_timeout: @receive_timeout_ms
             ) do
          {:ok, %Req.Response{status: 200, body: body}} ->
            parse_response(body)

          {:ok, %Req.Response{status: status}} ->
            {:error, Error.new(:audd_http, "AudD returned HTTP #{status}", %{status: status})}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error,
         Error.new(:read_snippet, "could not read the extracted snippet", %{reason: reason})}
    end
  end

  @doc "Pure parse of the AudD JSON envelope."
  @spec parse_response(map()) ::
          {:ok, %{artist: String.t(), title: String.t()}} | {:ok, :no_match} | {:error, term()}
  def parse_response(%{"status" => "success", "result" => %{"artist" => a, "title" => t}})
      when is_binary(a) and is_binary(t),
      do: {:ok, %{artist: a, title: t}}

  def parse_response(%{"status" => "success", "result" => nil}), do: {:ok, :no_match}

  def parse_response(%{"status" => "error"} = body) do
    {:error, Error.new(:audd_error, "AudD rejected the request", %{error: body["error"]})}
  end

  def parse_response(other) do
    {:error, Error.new(:audd_unexpected, "unexpected AudD response shape", %{body: other})}
  end

  defp token, do: Application.get_env(:beatgrid, __MODULE__, [])[:api_token]
  defp ffmpeg, do: Application.get_env(:beatgrid, __MODULE__, [])[:ffmpeg] || "ffmpeg"
end
