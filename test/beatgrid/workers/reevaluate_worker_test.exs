defmodule Beatgrid.Workers.ReevaluateWorkerTest do
  use Beatgrid.DataCase, async: false, oban: true

  import Mox
  import Beatgrid.Factory

  alias Beatgrid.AI.Mock, as: AIMock
  alias Beatgrid.Library.RenameSuggestion
  alias Beatgrid.Review
  alias Beatgrid.Workers.ReevaluateWorker

  setup :verify_on_exit!

  test "processes the scope and broadcasts running + done progress" do
    song = insert(:soundcharts_song, credit_name: "Caetano Veloso", name: "Cajuína")

    track =
      insert(:track,
        status: :present,
        tag_title: "Cajuina",
        filename: "Cajuina.mp3",
        rel_path: "_Inbox/Cajuina.mp3",
        soundcharts_song_id: song.id
      )

    {:ok, sug} =
      %RenameSuggestion{}
      |> RenameSuggestion.changeset(%{
        track_id: track.id,
        from_rel_path: track.rel_path,
        from_filename: track.filename,
        to_filename: "Caetano Veloso - Cajuína.mp3",
        status: :pending
      })
      |> Repo.insert()

    stub(AIMock, :complete, fn _p, _s, _o ->
      {:ok,
       %{
         "resolutions" => [
           %{
             "index" => 1,
             "same_recording" => false,
             "artist" => "Forró In The Dark",
             "title" => "Cajuína",
             "confidence" => 0.7,
             "rationale" => "versão forró"
           }
         ]
       }}
    end)

    Review.subscribe()

    assert :ok = perform_job(ReevaluateWorker, %{"scope" => "pending", "batch_id" => "b1"})

    assert_receive {:reevaluate_progress, %{batch_id: "b1", status: :running, total: 1}}
    assert_receive {:reevaluate_progress, %{batch_id: "b1", status: :done, updated: 1}}

    assert Repo.get(RenameSuggestion, sug.id).to_filename == "Forró In The Dark - Cajuína.mp3"
  end
end
