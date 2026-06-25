defmodule Beatgrid.Library.GenreFoldersTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Library.GenreFolders

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
      assert length(GenreFolders.list()) == 1
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
end
