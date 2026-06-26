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
      "Música Popular Brasileira — songwriter-driven Brazilian popular music: the broad " <>
        "samba, bossa nova, MPB, Tropicália and Brazilian pop/rock lineage. Melodic and " <>
        "lyric-forward, NOT forró (no baião/xote/arrasta-pé pulse, no sanfona-led groove). " <>
        "Use only when the track has no forró context — forró-origin MPB-leaning tracks go " <>
        "to `forro_mpb` instead."
  },
  %{
    key: "forro",
    display_name: "Forró",
    dir_name: "Forró",
    sort_order: 2,
    description:
      "General-purpose forró that doesn't clearly fit the other forró folders — modern / " <>
        "contemporary forró and forró universitário with a clear baião/xote/arrasta-pé pulse " <>
        "and accordion (sanfona). The default forró bucket: clearly forró, but not a " <>
        "traditional canon classic, not raw roots, not romantic/light, not psychedelic."
  },
  %{
    key: "forro_in_the_light",
    display_name: "Forró In The Light",
    dir_name: "Forró In The Light",
    sort_order: 3,
    description:
      "Romantic, mellow, easy-listening songs — slower, softer and more sentimental " <>
        "(forró romântico / love-song ballads). The defining trait is the calm, romantic " <>
        "mood rather than the rhythm; these are not necessarily forró at all."
  },
  %{
    key: "forro_classico",
    display_name: "Forró Clássico",
    dir_name: "Forró Clássico",
    sort_order: 4,
    description:
      "Classic forró standards and the traditional canon — the foundational pé-de-serra " <>
        "repertoire and its well-known standards (the Luiz Gonzaga / Jackson do Pandeiro / " <>
        "Dominguinhos lineage and the songs everyone knows). Established classics, not " <>
        "contemporary releases."
  },
  %{
    key: "forro_roots",
    display_name: "Forró Roots",
    dir_name: "Forró Roots",
    sort_order: 5,
    description:
      "Older, rootsier forró — raw, traditional pé-de-serra with an earthier, slightly " <>
        "different musicality (sanfona/zabumba/triângulo forward, vintage feel). Traditional " <>
        "like clássico but more obscure and raw, not the famous standards/canon."
  },
  %{
    key: "forro_psicodelico",
    display_name: "Forró Psicodélico",
    dir_name: "Forró Psicodélico",
    sort_order: 6,
    description:
      "Forró with psychedelic or electronic elements — synths, effects, experimental " <>
        "textures, or an electronic/psychedelic reinterpretation of forró. The forró pulse " <>
        "is present but the production is non-traditional and trippy/electronic."
  },
  %{
    key: "forro_mpb",
    display_name: "Forró MPB",
    dir_name: "Forró MPB",
    sort_order: 7,
    description:
      "Forró–MPB crossover — tracks that lean MPB/songwriter (melodic, lyric-forward) but " <>
        "come from a forró context. The user treats any forró-origin track as forró, so " <>
        "prefer this folder over `mpb` whenever the track's current/origin folder is already " <>
        "a forró one."
  }
]

for attrs <- folders do
  {:ok, _folder} = GenreFolders.upsert(attrs)
end

IO.puts("Seeded #{length(folders)} genre folders.")
