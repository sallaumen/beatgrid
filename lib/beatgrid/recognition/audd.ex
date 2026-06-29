defmodule Beatgrid.Recognition.Audd do
  @moduledoc """
  `Recognition` adapter via AudD (https://audd.io). Extracts an ~18s snippet from the
  segment's inner window with ffmpeg and uploads it. Paid — only from a button.
  """
  @behaviour Beatgrid.Recognition

  @endpoint "https://api.audd.io/"
  @snippet_ms 18_000

  @impl true
  def identify(audio_path, start_ms, end_ms) do
    case token() do
      t when is_binary(t) and t != "" ->
        with_snippet(audio_path, start_ms, end_ms, fn snippet -> post(snippet, t) end)

      _ ->
        {:error, :no_credentials}
    end
  end

  defp with_snippet(audio_path, start_ms, end_ms, fun) do
    offset = start_ms + min(60_000, round((end_ms - start_ms) * 0.3))
    dur = min(@snippet_ms, max(1_000, end_ms - offset))
    dest = Path.join(System.tmp_dir!(), "audd-#{System.unique_integer([:positive])}.mp3")
    args = ["-nostdin", "-ss", "#{offset / 1000}", "-t", "#{dur / 1000}", "-i", audio_path, "-ac", "1", "-y", dest]

    try do
      case System.cmd(ffmpeg(), args, stderr_to_stdout: true) do
        {_out, 0} -> fun.(dest)
        {out, code} -> {:error, {:ffmpeg_exit, code, String.slice(out, max(0, byte_size(out) - 300), 300)}}
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
    file_part = {File.read!(snippet), filename: "snippet.mp3", content_type: "audio/mpeg"}

    case Req.post(@endpoint, form_multipart: [api_token: tok, file: file_part]) do
      {:ok, %Req.Response{status: 200, body: body}} -> parse_response(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:audd_http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Pure parse of the AudD JSON envelope."
  @spec parse_response(map()) ::
          {:ok, %{artist: String.t(), title: String.t()}} | {:ok, :no_match} | {:error, term()}
  def parse_response(%{"status" => "success", "result" => %{"artist" => a, "title" => t}})
      when is_binary(a) and is_binary(t),
      do: {:ok, %{artist: a, title: t}}

  def parse_response(%{"status" => "success", "result" => nil}), do: {:ok, :no_match}
  def parse_response(%{"status" => "error"} = body), do: {:error, {:audd_error, body["error"]}}
  def parse_response(other), do: {:error, {:audd_unexpected, other}}

  defp token, do: Application.get_env(:beatgrid, __MODULE__, [])[:api_token]
  defp ffmpeg, do: Application.get_env(:beatgrid, __MODULE__, [])[:ffmpeg] || "ffmpeg"
end
