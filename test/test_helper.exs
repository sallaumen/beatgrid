# `:ffprobe`/`:ffmpeg`/`:librosa`-tagged tests shell out to the real binaries; excluded
# by default (run e.g. with `mix test --include ffprobe --include ffmpeg --include librosa`).
ExUnit.start(exclude: [:ffprobe, :ffmpeg, :librosa])
Ecto.Adapters.SQL.Sandbox.mode(Beatgrid.Repo, :manual)
