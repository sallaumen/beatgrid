# `:ffprobe`/`:ffmpeg`-tagged tests shell out to the real binaries; excluded by
# default (run them with `mix test --include ffprobe --include ffmpeg`).
ExUnit.start(exclude: [:ffprobe, :ffmpeg])
Ecto.Adapters.SQL.Sandbox.mode(Beatgrid.Repo, :manual)
