defmodule Beatgrid.YouTube.YtDlpTest do
  use ExUnit.Case, async: true

  alias Beatgrid.YouTube.YtDlp

  describe "parse/2" do
    test "turns tab-separated print lines into items with derived paths" do
      out = "abc\tDjavan - Sina\thttps://youtu.be/abc\ndef\tLuiz - Asa\thttps://youtu.be/def\n"

      assert [
               %{path: "/inbox/abc.mp3", title: "Djavan - Sina", url: "https://youtu.be/abc"},
               %{path: "/inbox/def.mp3", title: "Luiz - Asa", url: "https://youtu.be/def"}
             ] = YtDlp.parse(out, "/inbox")
    end

    test "ignores malformed lines" do
      assert [] = YtDlp.parse("garbage-without-tabs\n", "/inbox")
    end
  end

  describe "download/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ytdlp_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      prev = Application.get_env(:beatgrid, YtDlp, [])

      on_exit(fn ->
        Application.put_env(:beatgrid, YtDlp, prev)
        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    defp fake(dir, body, cfg \\ []) do
      path = Path.join(dir, "fake_ytdlp")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      Application.put_env(:beatgrid, YtDlp, Keyword.merge([executable: path], cfg))
      path
    end

    test "runs yt-dlp and returns parsed items", %{dir: dir} do
      fake(dir, ~s|printf 'abc\\tDjavan - Sina\\thttps://youtu.be/abc\\n'\n|)

      assert {:ok, [item]} = YtDlp.download("https://youtu.be/abc", dir)
      assert item.title == "Djavan - Sina"
      assert item.path == Path.join(dir, "abc.mp3")
    end

    test "returns {:error, :timeout} instead of hanging", %{dir: dir} do
      fake(dir, "sleep 5\n", timeout_ms: 200)
      assert {:error, :timeout} = YtDlp.download("u", dir)
    end
  end
end
