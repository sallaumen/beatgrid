defmodule Beatgrid.Soundcharts.ApiCall do
  @moduledoc """
  Ledger of every Soundcharts API call. `quota_remaining` comes from the
  `x-quota-remaining` response header; the latest value is the live budget.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "api_calls" do
    field :provider, :string, default: "soundcharts"
    field :endpoint, :string
    field :method, :string, default: "GET"
    field :request_params, :map, default: %{}
    field :http_status, :integer
    field :quota_remaining, :integer
    field :success, :boolean, default: false
    field :error, :map
    field :duration_ms, :integer
    field :occurred_at, :utc_datetime

    timestamps()
  end

  @castable ~w(provider endpoint method request_params http_status quota_remaining
               success error duration_ms occurred_at)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(call, attrs) do
    call
    |> cast(attrs, @castable)
    |> validate_required([:provider, :endpoint, :occurred_at])
  end
end
