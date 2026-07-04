defmodule Beatgrid.Sets.PlannerTest do
  use Beatgrid.DataCase, async: true

  alias Beatgrid.Sets
  alias Beatgrid.Sets.{PlanConfig, Planner}

  defp track(attrs) do
    {song_attrs, track_attrs} = Keyword.split(attrs, [:camelot, :tempo_bpm, :energy])

    song =
      insert(
        :soundcharts_song,
        Keyword.merge([camelot: "8A", tempo_bpm: 120.0, energy: 0.6], song_attrs)
      )

    insert(
      :track,
      Keyword.merge(
        [soundcharts_song_id: song.id, status: :present, genre_folder: "forro"],
        track_attrs
      )
    )
  end

  defp plan(set, params), do: Planner.run(set, PlanConfig.from_params(params))

  setup do
    for i <- 1..30, do: track(tag_artist: "Artist #{i}", tag_title: "Song #{i}")
    {:ok, set} = Sets.create("Set")
    %{set: set}
  end

  test "plans exactly the requested number of tracks", %{set: set} do
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "12"})
    assert length(Sets.tracks(set)) == 12
  end

  test "fill_mode :replace clears the set before planning", %{set: set} do
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "10"})
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "8", "fill_mode" => "replace"})
    assert length(Sets.tracks(set)) == 8
  end

  test "fill_mode :append keeps the current tracks and adds more", %{set: set} do
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "6"})
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "5", "fill_mode" => "append"})
    assert length(Sets.tracks(set)) == 11
  end

  test "excludes tracks that already live in another playlist", %{set: set} do
    {:ok, other} = Sets.create("Other")
    {:ok, _} = plan(other, %{"mode" => "tracks", "track_count" => "10"})
    other_ids = other |> Sets.tracks() |> MapSet.new(& &1.id)

    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "15", "exclude_set_ids" => [other.id]})

    planned = set |> Sets.tracks() |> MapSet.new(& &1.id)
    assert MapSet.disjoint?(planned, other_ids)
  end

  test "allow_styles pins the pool to the whitelisted folders", %{set: set} do
    track(tag_artist: "MPB One", genre_folder: "mpb")

    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "10", "allow_styles" => ["forro"]})

    folders = set |> Sets.tracks() |> Enum.map(& &1.genre_folder) |> Enum.uniq()
    assert folders == ["forro"]
  end

  test "secondary styles lose to primaries when nothing sets them apart", %{set: set} do
    # 7 roots (primary) vs 7 forró (secondary), all otherwise identical: the
    # tiered style score (20 vs 8) keeps every top-5 all-roots.
    roots =
      for i <- 1..7, into: MapSet.new() do
        track(tag_artist: "Roots #{i}", genre_folder: "forro_roots").id
      end

    for i <- 1..7, do: track(tag_artist: "Sec #{i}", genre_folder: "forro_secundario")

    {:ok, _} =
      plan(set, %{
        "mode" => "tracks",
        "track_count" => "2",
        "style_tier" => %{"forro_roots" => "primary", "forro_secundario" => "secondary"}
      })

    planned = set |> Sets.tracks() |> MapSet.new(& &1.id)
    assert MapSet.subset?(planned, roots)
  end

  test "a standout secondary-style track DOES get in (rating pulls it past the tier)", %{
    set: set
  } do
    for i <- 1..7, do: track(tag_artist: "Roots #{i}", genre_folder: "forro_roots")

    standouts =
      for i <- 1..7, into: MapSet.new() do
        t = track(tag_artist: "Standout #{i}", genre_folder: "forro_secundario")
        {:ok, r} = t |> Ecto.Changeset.change(%{rating: 10}) |> Beatgrid.Repo.update()
        r.id
      end

    {:ok, _} =
      plan(set, %{
        "mode" => "tracks",
        "track_count" => "2",
        "prioritize_rating" => "true",
        "style_tier" => %{"forro_roots" => "primary", "forro_secundario" => "secondary"}
      })

    planned = set |> Sets.tracks() |> MapSet.new(& &1.id)
    assert MapSet.subset?(planned, standouts)
  end

  test "styles outside the tiers stay out of the pool", %{set: set} do
    for i <- 1..7, do: track(tag_artist: "Roots #{i}", genre_folder: "forro_roots")

    {:ok, _} =
      plan(set, %{
        "mode" => "tracks",
        "track_count" => "10",
        "style_tier" => %{"forro_roots" => "primary"}
      })

    folders = set |> Sets.tracks() |> Enum.map(& &1.genre_folder) |> Enum.uniq()
    assert folders == ["forro_roots"]
  end

  test "bpm window bounds the pool", %{set: set} do
    track(tag_artist: "Fast", tempo_bpm: 165.0)

    {:ok, _} =
      plan(set, %{
        "mode" => "tracks",
        "track_count" => "10",
        "bpm_min" => "100",
        "bpm_max" => "140"
      })

    refute "Fast" in (set |> Sets.tracks() |> Enum.map(& &1.tag_artist))
  end

  test "avoid_artist_repeat spreads artists when alternatives exist", %{set: set} do
    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "12", "avoid_artist_repeat" => "true"})

    artists = set |> Sets.tracks() |> Enum.map(& &1.tag_artist)
    assert length(Enum.uniq(artists)) == length(artists)
  end

  test "by default the key does NOT chain the plan (no 9A-only playlists)", %{set: set} do
    # Seed the set on 9A, then offer 7 rated far-key (3B) tracks against the 30
    # unrated 9A-compatible pool. With harmony OFF (default) the rating is the
    # only tiebreak, so the picks must be the far-key rated ones.
    {:ok, _} = Sets.append(set, track(tag_artist: "Seed", camelot: "9A"))

    far =
      for i <- 1..7, into: MapSet.new() do
        t = track(tag_artist: "Far #{i}", camelot: "3B")
        {:ok, r} = t |> Ecto.Changeset.change(%{rating: 10}) |> Beatgrid.Repo.update()
        r.id
      end

    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "2", "fill_mode" => "append"})

    [_seed | planned] = Sets.tracks(set)
    assert length(planned) == 2
    assert Enum.all?(planned, &MapSet.member?(far, &1.id))
  end

  test "match_keys re-enables harmonic chaining", %{set: set} do
    {:ok, _} = Sets.append(set, track(tag_artist: "Seed", camelot: "9A"))

    far =
      for i <- 1..7, into: MapSet.new() do
        t = track(tag_artist: "Far #{i}", camelot: "3B")
        {:ok, r} = t |> Ecto.Changeset.change(%{rating: 10}) |> Beatgrid.Repo.update()
        r.id
      end

    {:ok, _} =
      plan(set, %{
        "mode" => "tracks",
        "track_count" => "2",
        "fill_mode" => "append",
        "match_keys" => "true"
      })

    # Harmony (25) dwarfs the far tracks' rating edge (2 + 2.5 harmony), so the
    # compatible pool wins every slot — none of the far-key tracks get in.
    [_seed | planned] = Sets.tracks(set)
    refute Enum.any?(planned, &MapSet.member?(far, &1.id))
  end

  test "connects consecutive pairs with transitions", %{set: set} do
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "5"})
    [_first | rest] = Sets.entries(set)
    assert rest != []
    assert Enum.all?(rest, & &1.transition)
  end

  test "gold_every guarantees at least one Selo Ouro in every window", %{set: set} do
    golden =
      for i <- 1..6, into: MapSet.new() do
        t = track(tag_artist: "Gold #{i}")

        {:ok, g} =
          t |> Ecto.Changeset.change(%{gold_status: :confirmed}) |> Beatgrid.Repo.update()

        g.id
      end

    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "15", "gold_every" => "5"})

    flags = set |> Sets.tracks() |> Enum.map(&MapSet.member?(golden, &1.id))
    assert length(flags) == 15

    for window <- Enum.chunk_every(flags, 5, 1, :discard) do
      assert true in window, "toda janela de 5 faixas deve ter pelo menos um ouro"
    end
  end

  test "gold gravitates to the pico slots and is saved elsewhere", %{set: set} do
    # Top-5 pinned by rating (2 gold + 3 non-gold); everything else identical.
    # A 3-slot :steady arc is [abertura, pico, abertura] — the single gold pick
    # must land exactly on the pico, the openers must spend the non-golds.
    golden =
      for i <- 1..2, into: MapSet.new() do
        t = track(tag_artist: "GoldTop #{i}")

        {:ok, g} =
          t
          |> Ecto.Changeset.change(%{rating: 10, gold_status: :confirmed})
          |> Beatgrid.Repo.update()

        g.id
      end

    for i <- 1..3 do
      t = track(tag_artist: "PlainTop #{i}")
      {:ok, _} = t |> Ecto.Changeset.change(%{rating: 10}) |> Beatgrid.Repo.update()
    end

    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "3", "arc_shape" => "steady"})

    entries = Sets.entries(set)
    assert [first, %{role: "pico"} = peak, last] = entries
    assert MapSet.member?(golden, peak.track.id), "o pico deve receber uma música ouro"
    refute MapSet.member?(golden, first.track.id), "a abertura deve poupar o ouro"
    refute MapSet.member?(golden, last.track.id), "o fecho deve poupar o ouro"
  end

  test "gold_every never stalls when the gold pool runs dry", %{set: set} do
    # No gold tracks at all — the quota falls back to normal picks.
    {:ok, _} = plan(set, %{"mode" => "tracks", "track_count" => "10", "gold_every" => "3"})
    assert length(Sets.tracks(set)) == 10
  end

  test "prioritize_rating surfaces the rated tracks without excluding unrated", %{set: set} do
    # 10 rated >= topk (5) + count (5): with identical camelot/bpm/energy only
    # the rating differentiates the score, so EVERY slot's top-5 pool is made of
    # rated tracks — deterministic even with the top-K random pick.
    rated =
      for i <- 1..10, into: MapSet.new() do
        t = track(tag_artist: "Rated #{i}")
        {:ok, r} = t |> Ecto.Changeset.change(%{rating: 10}) |> Beatgrid.Repo.update()
        r.id
      end

    {:ok, _} =
      plan(set, %{"mode" => "tracks", "track_count" => "5", "prioritize_rating" => "true"})

    planned = set |> Sets.tracks() |> MapSet.new(& &1.id)
    assert MapSet.size(planned) == 5
    assert MapSet.subset?(planned, rated)
  end

  test "duration mode fills roughly the requested minutes", %{set: set} do
    {:ok, _} = plan(set, %{"mode" => "duration", "duration_minutes" => "30"})
    assert length(Sets.tracks(set)) >= 2
  end
end
