defmodule Beatgrid.Mixing.StyleAffinity do
  @moduledoc """
  How well two genre folders mix in a set — the domain knowledge the set scorer
  uses to avoid blending styles that don't belong together (e.g. MPB and Forró
  Psicodélico inside a Forró Roots set).

  This is **soft**: an incompatible pair gets a low score (it sinks to the bottom
  of the suggestions, flagged), not a hard ban — the DJ can still add it by hand.

  The matrix lives here (config, no migration) and is the single source of truth:
  the UI's "Critérios" modal reads `tier/2` and `folders/0`, so changing a pair
  here changes what the screen shows. Each unordered pair is listed once; lookup
  tries both orders, so affinity is symmetric by construction.
  """

  @neutral 0.7
  @values %{combina: 1.0, cuidado: 0.5, evitar: 0.15}

  @folders ~w(mpb forro forro_classico forro_roots forro_in_the_light forro_psicodelico forro_mpb)

  @pairs %{
    # ✅ combinam
    {"mpb", "forro_mpb"} => :combina,
    {"forro", "forro_classico"} => :combina,
    {"forro", "forro_roots"} => :combina,
    {"forro_classico", "forro_roots"} => :combina,
    {"forro_in_the_light", "forro_mpb"} => :combina,
    # ⚠️ com cuidado
    {"mpb", "forro_in_the_light"} => :cuidado,
    {"forro", "forro_in_the_light"} => :cuidado,
    {"forro", "forro_mpb"} => :cuidado,
    {"forro_classico", "forro_in_the_light"} => :cuidado,
    {"forro_roots", "forro_in_the_light"} => :cuidado,
    {"forro_in_the_light", "forro_psicodelico"} => :cuidado,
    {"forro_psicodelico", "forro_mpb"} => :cuidado,
    # ❌ evitar
    {"mpb", "forro"} => :evitar,
    {"mpb", "forro_classico"} => :evitar,
    {"mpb", "forro_roots"} => :evitar,
    {"mpb", "forro_psicodelico"} => :evitar,
    {"forro", "forro_psicodelico"} => :evitar,
    {"forro_classico", "forro_psicodelico"} => :evitar,
    {"forro_classico", "forro_mpb"} => :evitar,
    {"forro_roots", "forro_psicodelico"} => :evitar,
    {"forro_roots", "forro_mpb"} => :evitar
  }

  @doc "Genre-folder keys the matrix knows, in canonical order."
  @spec folders() :: [String.t()]
  def folders, do: @folders

  @doc """
  Compatibility of two folders in `[0,1]`. Same folder = 1.0; a `nil` target style
  is neutral (`#{@neutral}`, no penalty); unknown pairs default to "with care".
  """
  @spec affinity(String.t() | nil, String.t() | nil) :: float()
  def affinity(nil, _b), do: @neutral
  def affinity(_a, nil), do: @neutral
  def affinity(a, a), do: 1.0

  def affinity(a, b) do
    tier = Map.get(@pairs, {a, b}) || Map.get(@pairs, {b, a}) || :cuidado
    Map.fetch!(@values, tier)
  end

  @doc "Display tier for a pair: `:combina | :cuidado | :evitar`."
  @spec tier(String.t() | nil, String.t() | nil) :: :combina | :cuidado | :evitar
  def tier(a, b) do
    cond do
      affinity(a, b) >= 0.85 -> :combina
      affinity(a, b) >= 0.4 -> :cuidado
      true -> :evitar
    end
  end
end
