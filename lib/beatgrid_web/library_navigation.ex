defmodule BeatgridWeb.LibraryNavigation do
  @moduledoc "Canonical, shareable Biblioteca filters and safe return paths for track details."

  alias Beatgrid.Soundcharts.Camelot

  @text_filters ~w(search genre_folder tag)a
  @flag_filters ~w(unclassified gold camelot_compatible)a
  @integer_filters ~w(rating_min rating_max)a
  @number_filters ~w(bpm_min bpm_max energy_min energy_max)a
  @filter_keys @text_filters ++
                 @flag_filters ++ @integer_filters ++ @number_filters ++ ~w(confidence camelot)a
  @sort_fields ~w(artist folder bpm key energy rating loudness confidence)a
  @default_sort {:artist, :asc}

  @doc "Extracts only recognized filters from a URL or current view state."
  def filters(params) do
    for key <- @filter_keys,
        value = normalize(key, Map.get(params, key) || Map.get(params, Atom.to_string(key))),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp normalize(key, value) when key in @text_filters and is_binary(value) do
    if String.trim(value) != "", do: value
  end

  defp normalize(key, value) when key in @flag_filters and value in [true, "true"], do: true
  defp normalize(:confidence, value) when value in ~w(high medium low), do: value

  defp normalize(:camelot, value) when is_binary(value) do
    if Camelot.neighbors(value) != [], do: value
  end

  defp normalize(key, value) when key in @integer_filters and is_integer(value),
    do: normalize(key, Integer.to_string(value))

  defp normalize(key, value) when key in @integer_filters and is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..10 -> value
      _ -> nil
    end
  end

  defp normalize(key, value) when key in @number_filters and is_number(value),
    do: normalize(key, to_string(value))

  defp normalize(key, value) when key in @number_filters and is_binary(value) do
    case Float.parse(value) do
      {_n, ""} -> value
      _ -> nil
    end
  end

  defp normalize(_key, _value), do: nil

  @doc "Maps a displayed sort field to its whitelisted atom."
  def sort_field(value), do: Enum.find(@sort_fields, &(Atom.to_string(&1) == value))

  def sort(params) do
    case sort_field(params["sort"]) do
      nil -> @default_sort
      field -> {field, if(params["dir"] == "desc", do: :desc, else: :asc)}
    end
  end

  @doc "A canonical library path carrying all active filters and non-default sorting."
  def path(filters, sort) do
    entries = filters(filters)

    entries =
      if sort == @default_sort,
        do: entries,
        else: Map.merge(entries, %{sort: elem(sort, 0), dir: elem(sort, 1)})

    case Enum.sort(entries) do
      [] -> "/"
      entries -> "/?" <> URI.encode_query(entries)
    end
  end

  @doc "Accepts only the local Library route; strips all unknown and unsafe URL parameters."
  def return_path("/?" <> query) do
    with true <- valid_query?(query),
         params = URI.decode_query(query),
         true <- Enum.all?(params, fn {key, value} -> valid_text?(key) and valid_text?(value) end) do
      path(filters(params), sort(params))
    else
      _ -> "/"
    end
  rescue
    ArgumentError -> "/"
  end

  def return_path(_), do: "/"

  # The only accepted outer route is the literal `/?`. Raw fragments and
  # invalid query escapes must not become filter values after reconstruction.
  defp valid_query?(query) do
    String.valid?(query) and not Regex.match?(~r/[#\x00-\x20\x7F]|%(?![0-9a-fA-F]{2})/, query)
  end

  defp valid_text?(text), do: String.valid?(text) and not Regex.match?(~r/[\x00-\x1F\x7F]/, text)
end
