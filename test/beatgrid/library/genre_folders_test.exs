defmodule Beatgrid.Library.GenreFoldersTest do
  # async: false — these tests insert genre folders with fixed unique keys plus
  # tracks/suggestions; running concurrently with other folder-inserting async
  # tests can deadlock on the genre_folders.key unique index.
  use Beatgrid.DataCase, async: false

  import Beatgrid.Factory

  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Organization

  describe "upsert/1 and list/0" do
    test "upserts a folder and lists it" do
      assert {:ok, folder} =
               GenreFolders.upsert(%{
                 key: "mpb",
                 display_name: "MPB",
                 dir_name: "MPB",
                 description: "Brazilian popular music.",
                 sort_order: 1
               })

      assert folder.key == "mpb"
      assert [%{key: "mpb"}] = GenreFolders.list()
    end

    test "is idempotent by key (updates instead of duplicating)" do
      attrs = %{key: "forro", display_name: "Forró", dir_name: "Forró", sort_order: 2}
      assert {:ok, _} = GenreFolders.upsert(attrs)
      assert {:ok, updated} = GenreFolders.upsert(%{attrs | display_name: "Forró (edited)"})

      assert updated.display_name == "Forró (edited)"
      assert [_] = GenreFolders.list()
    end

    test "requires key, display_name and dir_name" do
      assert {:error, changeset} = GenreFolders.upsert(%{key: "x"})

      assert %{display_name: ["can't be blank"], dir_name: ["can't be blank"]} =
               errors_on(changeset)
    end
  end

  describe "get_by_key/1" do
    test "returns the folder or nil" do
      {:ok, _} =
        GenreFolders.upsert(%{
          key: "forro_roots",
          display_name: "Forró Roots",
          dir_name: "Forró Roots",
          sort_order: 5
        })

      assert %{key: "forro_roots"} = GenreFolders.get_by_key("forro_roots")
      assert GenreFolders.get_by_key("nope") == nil
    end
  end

  describe "list/0" do
    test "orders by sort_order" do
      {:ok, _} = GenreFolders.upsert(%{key: "b", display_name: "B", dir_name: "B", sort_order: 2})
      {:ok, _} = GenreFolders.upsert(%{key: "a", display_name: "A", dir_name: "A", sort_order: 1})

      assert ["a", "b"] = Enum.map(GenreFolders.list(), & &1.key)
    end
  end

  describe "update/2" do
    test "changes a folder's description" do
      folder =
        insert(:genre_folder,
          key: "mpb",
          display_name: "MPB",
          dir_name: "MPB",
          description: "old"
        )

      assert {:ok, updated} =
               GenreFolders.update(folder, %{description: "Songwriter-driven MPB."})

      assert updated.description == "Songwriter-driven MPB."
      assert GenreFolders.get_by_key("mpb").description == "Songwriter-driven MPB."
    end
  end

  describe "create/1" do
    test "inserts a new folder" do
      assert {:ok, folder} =
               GenreFolders.create(%{
                 key: "samba",
                 display_name: "Samba",
                 dir_name: "Samba",
                 description: "",
                 sort_order: 3
               })

      assert folder.key == "samba"
      assert GenreFolders.get_by_key("samba")
    end

    test "returns a changeset error on a duplicate key" do
      insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")

      assert {:error, changeset} =
               GenreFolders.create(%{key: "samba", display_name: "Samba 2", dir_name: "Samba 2"})

      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "in_use?/1" do
    test "false for an empty folder" do
      folder = insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")

      refute GenreFolders.in_use?(folder)
      refute GenreFolders.in_use?("samba")
    end

    test "true when a track references the key" do
      insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
      insert(:track, genre_folder: "samba", status: :present)

      assert GenreFolders.in_use?("samba")
    end

    test "true when a pending move suggestion targets the key" do
      insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
      track = insert(:track, status: :present)

      {:ok, _} =
        Beatgrid.Organization.create_suggestion(%{
          track_id: track.id,
          from_rel_path: track.rel_path,
          to_genre_folder: "samba",
          source: :rule,
          status: :pending
        })

      assert GenreFolders.in_use?("samba")
    end

    test "false when only a non-pending suggestion targets the key" do
      insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
      track = insert(:track, status: :present)

      {:ok, _} =
        Beatgrid.Organization.create_suggestion(%{
          track_id: track.id,
          from_rel_path: track.rel_path,
          to_genre_folder: "samba",
          source: :rule,
          status: :rejected
        })

      refute GenreFolders.in_use?("samba")
    end
  end

  describe "delete/1" do
    test "deletes an empty folder" do
      folder = insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")

      assert {:ok, _} = GenreFolders.delete(folder)
      assert GenreFolders.get_by_key("samba") == nil
    end

    test "refuses to delete a folder in use" do
      folder = insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
      insert(:track, genre_folder: "samba", status: :present)

      assert {:error, :in_use} = GenreFolders.delete(folder)
      assert GenreFolders.get_by_key("samba")
    end
  end

  describe "create_from_name/2" do
    test "slugs the accented name into the key, mirrors dir_name, appends the sort order" do
      insert(:genre_folder, sort_order: 7)

      assert {:ok, folder} = GenreFolders.create_from_name("  Forró Novo  ", "#123456")
      assert folder.key == "forro_novo"
      assert folder.display_name == "Forró Novo"
      assert folder.dir_name == "Forró Novo"
      assert folder.color == "#123456"
      assert folder.sort_order == 8
    end

    test "the first folder starts the sort order at 0 and gets the default color" do
      assert {:ok, folder} = GenreFolders.create_from_name("Samba", nil)
      assert folder.sort_order == 0
      assert folder.color == "#9498a6"
    end

    test "a name that slugs to nothing is invalid" do
      assert {:error, :invalid_name} = GenreFolders.create_from_name("!!!", nil)
    end

    test "a duplicate name returns the changeset error" do
      insert(:genre_folder, key: "samba", display_name: "Samba", dir_name: "Samba")
      assert {:error, %Ecto.Changeset{}} = GenreFolders.create_from_name("Samba", nil)
    end
  end

  describe "in_use_keys/0" do
    test "collects track folders and pending move targets in one pass, ignoring the rest" do
      insert(:track, genre_folder: "samba", status: :present)
      insert(:genre_folder, key: "vazio", display_name: "Vazio", dir_name: "Vazio")

      t = insert(:track)

      {:ok, _} =
        Organization.create_suggestion(%{
          track_id: t.id,
          from_rel_path: t.rel_path,
          to_genre_folder: "roots",
          source: :claude
        })

      keys = GenreFolders.in_use_keys()

      assert "samba" in keys
      assert "roots" in keys
      refute "vazio" in keys
    end
  end
end
