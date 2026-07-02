defmodule Beatgrid.Events do
  @moduledoc """
  The PubSub contract: every topic, who broadcasts on it, and the exact message
  shapes it carries. Each context still OWNS its `subscribe/0` + `broadcast_*`
  helpers (call those, never `Phoenix.PubSub` directly) — this module is the one
  place to see the whole event map, so a payload change starts by updating the
  type here and following the compiler/greps to every consumer.

  | Topic             | Owner (subscribe/broadcast)       | Messages                                            | Consumed by                    |
  | ----------------- | --------------------------------- | --------------------------------------------------- | ------------------------------ |
  | `analysis`        | `Beatgrid.Analysis`               | `{:analysis_tick}`                                  | Painel                         |
  | `loudness`        | `Beatgrid.Loudness`               | `{:loudness_tick}`                                  | Painel                         |
  | `youtube`         | `Beatgrid.YouTube`                | `{:youtube_tick}`                                   | Painel                         |
  | `enrich`          | `Beatgrid.YouTube` (`_enrich`)    | `{:enrich_progress, enrich_progress()}`             | Painel, Detalhe da faixa       |
  | `reevaluate`      | `Beatgrid.Review`                 | `{:reevaluate_progress, reevaluate_progress()}`, `{:re_resolve_done, re_resolve_done()}`, `{:review_applied, batch_result()}`, `{:batch_undone, undo_result()}` | Central de Revisão |
  | `import`          | `Beatgrid.Library` (`_import`)    | `{:import_progress, import_progress()}`             | Biblioteca                     |
  | `mixes`           | `Beatgrid.Mixes`                  | `{:mix_progress, mix_progress()}`                   | Sets online (lista + estudo)   |
  | `dedup`           | `Beatgrid.Dedup`                  | `{:dedup_progress, dedup_progress()}`               | Duplicatas                     |
  | `recommendations` | `Beatgrid.Repertoire`             | `{:recommend_progress, recommend_progress()}`       | Painel, Detalhe da faixa       |
  | `now_playing`     | `Beatgrid.Playback`               | `{:now_playing, now_playing()}`                     | Player + todas as telas        |
  | `markers`         | `Beatgrid.Playback` (`_markers`)  | `{:markers_changed, track_id}`                      | Player, Detalhe da faixa       |
  | `sets:<id>`       | `Beatgrid.Sets` (`subscribe_set`) | `{:set_changed, set_id}`                            | Discotecagem (hint revalidation) |
  """

  @typedoc "Pointer to what is playing — never the track itself."
  @type now_playing :: %{track_id: Ecto.UUID.t() | nil, set_id: Ecto.UUID.t() | nil}

  @typedoc """
  Per-item progress of an enrich batch (scope: track | pending | rare). The rare
  scope's final tick also carries the classification counts
  (classified/suggested/auto_filed/agreed/errors) for the Painel summary.
  """
  @type enrich_progress :: %{
          :batch_id => Ecto.UUID.t(),
          :scope => String.t(),
          :id => Ecto.UUID.t() | nil,
          :status => :running | :refining | :finishing | :done,
          :done => non_neg_integer(),
          :total => non_neg_integer(),
          optional(:resolved) => non_neg_integer(),
          optional(:budget_exhausted) => boolean(),
          optional(:classified) => non_neg_integer(),
          optional(:suggested) => non_neg_integer(),
          optional(:auto_filed) => non_neg_integer(),
          optional(:agreed) => non_neg_integer(),
          optional(:errors) => non_neg_integer()
        }

  @typedoc "Chunked progress of an AI re-evaluation run (`updated` only on the final tick)."
  @type reevaluate_progress :: %{
          :batch_id => Ecto.UUID.t(),
          :status => :running | :done,
          :done => non_neg_integer(),
          :total => non_neg_integer(),
          optional(:updated) => non_neg_integer()
        }

  @typedoc "Completion of a single re-resolve (audit tab)."
  @type re_resolve_done :: %{
          suggestion_id: Ecto.UUID.t(),
          outcome: :resolved | :no_match | :budget_exhausted | :error
        }

  @typedoc "Result of applying a review batch to disk."
  @type batch_result :: %{
          batch_id: Ecto.UUID.t(),
          applied: non_neg_integer(),
          failed: non_neg_integer()
        }

  @typedoc "Result of undoing an operations batch."
  @type undo_result :: %{undone: non_neg_integer(), failed: non_neg_integer()}

  @typedoc "Per-file progress of a background import commit."
  @type import_progress :: %{
          :batch_id => Ecto.UUID.t(),
          :status => :running | :done,
          :done => non_neg_integer(),
          :total => non_neg_integer(),
          :imported => non_neg_integer(),
          optional(:skipped) => non_neg_integer()
        }

  @typedoc "Stage ticks of an online-set pipeline (download/analyze/recognize/DJ detection)."
  @type mix_progress :: %{
          :mix_id => Ecto.UUID.t(),
          optional(:status) => atom(),
          optional(:stage) => String.t(),
          optional(:done) => non_neg_integer(),
          optional(:total) => non_neg_integer(),
          optional(:matched) => non_neg_integer(),
          optional(:no_match) => non_neg_integer(),
          optional(:error) => non_neg_integer()
        }

  @typedoc "Progress of a duplicate-detection rebuild."
  @type dedup_progress :: %{
          :status => :running | :done,
          :batch_id => Ecto.UUID.t(),
          optional(:groups) => non_neg_integer()
        }

  @typedoc "Progress of an AI recommendation run (scope: folder | track)."
  @type recommend_progress :: %{
          batch_id: Ecto.UUID.t(),
          scope: String.t(),
          key: String.t() | Ecto.UUID.t(),
          status: :running | :done | :error,
          count: non_neg_integer()
        }
end
