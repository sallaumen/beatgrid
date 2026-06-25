# Seeds — idempotent. Run with `mix run priv/repo/seeds.exs` (part of `mix ecto.setup`).
#
# Seeds the six genre folders and their classification rubric. The `description`
# is fed to the AI classifier and is freely editable later.

alias Beatgrid.Library.GenreFolders

folders = [
  %{
    key: "mpb",
    display_name: "MPB",
    dir_name: "MPB",
    sort_order: 1,
    description:
      "Música Popular Brasileira — songwriter-driven Brazilian popular music " <>
        "(the broad samba/bossa/pop/rock lineage), not forró."
  },
  %{
    key: "forro",
    display_name: "Forró",
    dir_name: "Forró",
    sort_order: 2,
    description:
      "General forró that doesn't clearly fit roots, clássico, in-the-light, or psicodélico."
  },
  %{
    key: "forro_in_the_light",
    display_name: "Forró In The Light",
    dir_name: "Forró In The Light",
    sort_order: 3,
    description: "More romantic, mellow songs — not necessarily forró."
  },
  %{
    key: "forro_classico",
    display_name: "Forró Clássico",
    dir_name: "Forró Clássico",
    sort_order: 4,
    description: "Classic forró standards and the traditional canon."
  },
  %{
    key: "forro_roots",
    display_name: "Forró Roots",
    dir_name: "Forró Roots",
    sort_order: 5,
    description: "Older forró with a more traditional, slightly different musicality."
  },
  %{
    key: "forro_psicodelico",
    display_name: "Forró Psicodélico",
    dir_name: "Forró Psicodélico",
    sort_order: 6,
    description: "Forró with electronic / psychedelic elements."
  },
  %{
    key: "forro_mpb",
    display_name: "Forró MPB",
    dir_name: "Forró MPB",
    sort_order: 7,
    description:
      "Forró-MPB crossover — tracks that lean MPB / songwriter but come from a forró " <>
        "context. The user treats forró-origin tracks as forró, so prefer this over `mpb` " <>
        "when a track's current folder is already a forró one."
  }
]

for attrs <- folders do
  {:ok, _folder} = GenreFolders.upsert(attrs)
end

IO.puts("Seeded #{length(folders)} genre folders.")
