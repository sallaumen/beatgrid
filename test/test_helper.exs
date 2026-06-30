# `:ffprobe`/`:ffmpeg`/`:mp3gain`/`:librosa`-tagged tests shell out to real binaries;
# excluded by default (run e.g. with `mix test --include ffprobe --include ffmpeg`).
ExUnit.start(exclude: [:ffprobe, :ffmpeg, :mp3gain, :librosa])
Ecto.Adapters.SQL.Sandbox.mode(Beatgrid.Repo, :manual)
