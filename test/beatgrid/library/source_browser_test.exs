defmodule Beatgrid.Library.SourceBrowserTest do
  use ExUnit.Case, async: true

  alias Beatgrid.Library.SourceBrowser

  @tag :tmp_dir
  test "lists subdirs first and only import-candidate files, dotfiles hidden", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "zeta"))
    File.mkdir_p!(Path.join(root, "Alfa"))
    File.mkdir_p!(Path.join(root, ".oculta"))
    File.write!(Path.join(root, "b.mp3"), "x")
    File.write!(Path.join(root, "A.mp4"), "x")
    File.write!(Path.join(root, "capa.jpg"), "x")
    File.write!(Path.join(root, "notas.txt"), "x")
    File.write!(Path.join(root, ".DS_Store"), "x")

    assert {:ok, listing} = SourceBrowser.list(root)
    assert listing.dir == root
    assert listing.parent == Path.dirname(root)

    # Case-insensitive alphabetical, dirs and files separated.
    assert Enum.map(listing.dirs, & &1.name) == ["Alfa", "zeta"]
    assert Enum.map(listing.files, & &1.name) == ["A.mp4", "b.mp3"]
    assert %{path: path} = hd(listing.files)
    assert path == Path.join(root, "A.mp4")
  end

  test "the filesystem root has no parent" do
    assert {:ok, %{parent: nil}} = SourceBrowser.list("/")
  end

  @tag :tmp_dir
  test "a path that is not a directory is an error", %{tmp_dir: root} do
    file = Path.join(root, "faixa.mp3")
    File.write!(file, "x")

    assert {:error, :not_a_dir} = SourceBrowser.list(file)
    assert {:error, :not_a_dir} = SourceBrowser.list(Path.join(root, "nope"))
  end

  @tag :tmp_dir
  test "expands ~ and relative segments before listing", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "sub"))
    assert {:ok, %{dir: dir}} = SourceBrowser.list(Path.join(root, "sub/.."))
    assert dir == root
  end

  test "start_dir/0 prefers ~/Downloads and falls back to home" do
    dir = SourceBrowser.start_dir()
    assert File.dir?(dir)
  end
end
