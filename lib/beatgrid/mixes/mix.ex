defmodule Beatgrid.Mixes.Mix do
  @moduledoc "A recorded DJ set imported from an online source (e.g. SoundCloud) for study."
  use Ecto.Schema

  import Ecto.Changeset

  alias Beatgrid.Mixes.Segment

  @type t :: %__MODULE__{}

  @statuses [:downloading, :analyzing, :ready, :failed]

  @primary_key {:id, Uniq.UUID, autogenerate: true, version: 7, type: :uuid}
  @foreign_key_type Uniq.UUID
  @timestamps_opts [type: :utc_datetime]

  schema "mixes" do
    field :source, :string
    field :source_url, :string
    field :title, :string
    field :dj, :string
    field :duration_ms, :integer
    field :audio_path, :string
    field :description, :string
    field :status, Ecto.Enum, values: @statuses, default: :downloading
    field :error, :string
    field :analyzed_at, :utc_datetime
    field :cleanup_job_id, :integer
    field :audio_deleted_at, :utc_datetime

    has_many :segments, Segment, preload_order: [asc: :position]

    timestamps()
  end

  @fields ~w(source source_url title dj duration_ms audio_path description status
             error analyzed_at cleanup_job_id audio_deleted_at)a

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(mix, attrs) do
    mix
    |> cast(attrs, @fields)
    |> validate_required([:source, :source_url])
    |> unique_constraint(:source_url)
  end
end
