defmodule Beatgrid.Organization.SuggestTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Organization

  @rules %{"MPBzera" => "mpb", "Rooteira boaa" => "forro_roots"}

  describe "suggest_by_rule/1" do
    test "creates a pending suggestion per inbox track matching a playlist rule" do
      t_1 =
        insert(:track, source_playlist: "MPBzera", genre_folder: nil, rel_path: "_Inbox/a.mp3")

      t_2 =
        insert(:track,
          source_playlist: "Rooteira boaa",
          genre_folder: nil,
          rel_path: "_Inbox/b.mp3"
        )

      _none =
        insert(:track, source_playlist: "Unknown", genre_folder: nil, rel_path: "_Inbox/c.mp3")

      assert {:ok, %{created: 2, batch_id: _batch}} = Organization.suggest_by_rule(@rules)

      pending = Organization.list_by(status: :pending)
      assert [_, _] = pending
      assert Enum.find(pending, &(&1.track_id == t_1.id)).to_genre_folder == "mpb"
      assert Enum.find(pending, &(&1.track_id == t_2.id)).to_genre_folder == "forro_roots"
    end

    test "does not suggest for tracks already placed in a genre folder" do
      insert(:track, source_playlist: "MPBzera", genre_folder: "mpb", rel_path: "MPB/a.mp3")

      assert {:ok, %{created: 0}} = Organization.suggest_by_rule(@rules)
    end

    test "does not re-suggest a track that already has a pending suggestion" do
      insert(:track, source_playlist: "MPBzera", genre_folder: nil, rel_path: "_Inbox/a.mp3")

      assert {:ok, %{created: 1}} = Organization.suggest_by_rule(@rules)
      assert {:ok, %{created: 0}} = Organization.suggest_by_rule(@rules)
      assert [_] = Organization.list_by(status: :pending)
    end
  end
end
