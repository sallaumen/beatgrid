defmodule BeatgridWeb.TrackIdentityTest do
  use ExUnit.Case, async: true

  alias BeatgridWeb.TrackIdentity

  defp track(id, title, artist, filename) do
    %{id: id, tag_title: title, tag_artist: artist, filename: filename}
  end

  test "marks distinct recordings sharing a displayed title and artist, not repeated rows" do
    first = track("a", "Águas de Março", "João", "v1.mp3")
    second = track("b", "aguas de marco", "JOAO", "v2.mp3")
    separate = track("c", "Águas de Março", "Maria", "v3.mp3")

    assert TrackIdentity.ambiguous_ids([first, first, second, separate]) == MapSet.new(["a", "b"])
    assert TrackIdentity.ambiguous_ids([first, first, separate]) == MapSet.new()
  end

  test "uses the displayed filename when title and artist are missing" do
    first = track("a", nil, nil, "Forró.mp3")
    second = track("b", nil, nil, "Forro.mp3")
    other = track("c", nil, nil, "Outra.mp3")

    assert TrackIdentity.ambiguous_ids([first, second, other]) == MapSet.new(["a", "b"])
  end
end
