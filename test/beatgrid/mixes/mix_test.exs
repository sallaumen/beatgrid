defmodule Beatgrid.Mixes.MixTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Mixes.Mix

  test "requires source and source_url" do
    cs = Mix.changeset(%Mix{}, %{})
    refute cs.valid?
    assert %{source: ["can't be blank"], source_url: ["can't be blank"]} = errors_on(cs)
  end

  test "valid with the required fields and defaults status to downloading" do
    cs = Mix.changeset(%Mix{}, %{source: "soundcloud", source_url: "https://snd.sc/x"})
    assert cs.valid?
    assert Ecto.Changeset.apply_changes(cs).status == :downloading
  end
end
