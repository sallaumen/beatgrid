defmodule BeatgridWeb.LibraryNavigationTest do
  use ExUnit.Case, async: true

  alias BeatgridWeb.LibraryNavigation, as: Navigation

  test "round-trips all recognized flags, text, ranges and sort without importing or navigating away" do
    params = %{
      "search" => "Sina & Djavan",
      "genre_folder" => "mpb",
      "tag" => "Pico da pista",
      "confidence" => "high",
      "camelot" => "8A",
      "camelot_compatible" => "true",
      "unclassified" => "true",
      "gold" => "true",
      "rating_min" => "0",
      "rating_max" => "10",
      "bpm_min" => "90.5",
      "bpm_max" => "120",
      "energy_min" => "10",
      "energy_max" => "80",
      "sort" => "bpm",
      "dir" => "desc"
    }

    path = Navigation.path(Navigation.filters(params), Navigation.sort(params))
    assert URI.decode_query(URI.parse(path).query) == params
    assert Navigation.return_path(path) == path

    assert Navigation.return_path(path <> "&importar=1&redirect=https%3A%2F%2Fevil.example") ==
             path
  end

  test "retains an encoded fragment character when it belongs to a search term" do
    assert Navigation.return_path("/?search=Forr%C3%B3+%231") == "/?search=Forr%C3%B3+%231"
  end

  test "rejects other destinations and invalid filter values" do
    for value <- [
          nil,
          %{},
          "https://evil.example/?search=X",
          "//evil.example/",
          "/track/1",
          "/importados?origem=local",
          "/?importar=1",
          "/#elsewhere",
          "/?search=Sina#fragment",
          "/./?search=Sina",
          "/%2F?search=Sina",
          "/\\?search=Sina",
          " /?search=Sina",
          "/?search=one two",
          "/?search=%invalid",
          "/?search=%FF",
          "/?search=%00",
          <<"/?search=", 255>>,
          "/?confidence=not_an_atom&gold=false&camelot=99Z&rating_min=bad&sort=unknown&dir=desc"
        ] do
      assert Navigation.return_path(value) == "/"
    end
  end
end
