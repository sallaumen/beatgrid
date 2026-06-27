defmodule Beatgrid.Workers.RecommendWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true
  import Mox
  alias Beatgrid.Repertoire
  alias Beatgrid.Workers.RecommendWorker
  setup :set_mox_global

  test "folder scope persists deduped recommendations and broadcasts done" do
    insert(:genre_folder, key: "mpb", display_name: "MPB", dir_name: "MPB")

    stub(Beatgrid.AI.Mock, :complete, fn _p, _s, _o ->
      {:ok, %{"gaps" => [%{"artist" => "Elis", "song" => "Madalena", "reason" => "canon"}]}}
    end)

    Repertoire.subscribe()

    assert :ok =
             perform_job(RecommendWorker, %{
               "scope" => "folder",
               "folder" => "mpb",
               "batch_id" => "b1"
             })

    assert_receive {:recommend_progress, %{batch_id: "b1", status: :done}}

    assert [%{artist: "Elis", youtube_query: "Elis Madalena", source: :gaps}] =
             Repertoire.list_recommendations(genre_folder: "mpb")

    # re-run dedups → still 1
    assert :ok =
             perform_job(RecommendWorker, %{
               "scope" => "folder",
               "folder" => "mpb",
               "batch_id" => "b2"
             })

    assert Repertoire.count_recommendations(genre_folder: "mpb") == 1
  end

  test "unknown folder cancels" do
    assert {:cancel, :unknown_folder} =
             perform_job(RecommendWorker, %{
               "scope" => "folder",
               "folder" => "nope",
               "batch_id" => "b"
             })
  end
end
