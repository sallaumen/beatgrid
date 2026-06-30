defmodule Beatgrid.Audio.GainApplierCliTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Audio.GainApplierCli

  describe "mp3gain_steps/1" do
    test "rounds the gain to 1.5 dB mp3gain steps" do
      assert GainApplierCli.mp3gain_steps(0.7) == 0
      assert GainApplierCli.mp3gain_steps(0.8) == 1
      assert GainApplierCli.mp3gain_steps(2.2) == 1
      assert GainApplierCli.mp3gain_steps(2.3) == 2
      assert GainApplierCli.mp3gain_steps(-0.7) == 0
      assert GainApplierCli.mp3gain_steps(-0.8) == -1
      assert GainApplierCli.mp3gain_steps(-2.3) == -2
    end
  end

  @tag :ffmpeg
  @tag :tmp_dir
  test "applies gain through ffmpeg using an atomic rewrite", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tone.wav")

    {_out, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -hide_banner -nostats -f lavfi -i sine=frequency=440:duration=0.2 -c:a pcm_s16le) ++
          [path],
        stderr_to_stdout: true
      )

    assert :ok = GainApplierCli.apply(path, 1.0)
    assert File.regular?(path)
    assert File.stat!(path).size > 0
    refute File.exists?(Path.join(tmp_dir, ".gain-tone.wav"))
  end

  @tag :mp3gain
  @tag :tmp_dir
  test "applies MP3 gain losslessly with mp3gain when available", %{tmp_dir: tmp_dir} do
    if System.find_executable("mp3gain") do
      path = Path.join(tmp_dir, "sample.mp3")
      File.cp!("test/support/fixtures/sample.mp3", path)

      assert :ok = GainApplierCli.apply(path, 1.5)
      assert File.regular?(path)
      assert File.stat!(path).size > 0
    end
  end
end
