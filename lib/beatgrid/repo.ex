defmodule Beatgrid.Repo do
  use Ecto.Repo,
    otp_app: :beatgrid,
    adapter: Ecto.Adapters.Postgres
end
