defmodule Beatgrid.Mixes.DjPartTest do
  use Beatgrid.DataCase, async: true
  import Beatgrid.Factory
  alias Beatgrid.Mixes.DjPart

  test "changeset requires the spans + source" do
    cs = DjPart.changeset(%DjPart{}, %{})
    refute cs.valid?
  end

  test "valid changeset" do
    mix = insert(:mix)

    cs =
      DjPart.changeset(%DjPart{}, %{
        mix_id: mix.id,
        position: 0,
        start_ms: 0,
        end_ms: 1000,
        source: :manual
      })

    assert cs.valid?
  end
end
