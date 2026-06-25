# `:ffprobe`-tagged tests shell out to the real ffprobe binary; excluded by default
# (run them with `mix test --include ffprobe`).
ExUnit.start(exclude: [:ffprobe])
Ecto.Adapters.SQL.Sandbox.mode(Beatgrid.Repo, :manual)
