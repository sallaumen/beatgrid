defmodule BeatgridWeb.GenresLive do
  @moduledoc """
  Edit the genre-folder descriptions — the classification rubric the AI uses for
  both classification and rename verification. Editing here improves every AI pass.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.GenreFolders

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, folders: GenreFolders.list(), toast: nil)}
  end

  @impl true
  def handle_event("save_description", %{"key" => key, "description" => description}, socket) do
    toast =
      case GenreFolders.get_by_key(key) do
        nil ->
          {:error, :unknown_folder}

        folder ->
          with {:ok, _} <- GenreFolders.update(folder, %{description: description}),
               do: {:saved, key}
      end

    {:noreply, assign(socket, folders: GenreFolders.list(), toast: toast)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={:generos} socket={@socket}>
      <div class="mx-auto max-w-3xl px-6 py-8">
        <h1 class="text-[22px] font-semibold">Gêneros</h1>
        <p class="text-ink-muted mt-1 text-body-sm">
          A descrição de cada pasta é o contexto que a IA usa pra classificar e pra verificar os
          renomes. Quanto melhor a descrição, mais espertas as sugestões.
        </p>

        <p :if={match?({:saved, _}, @toast)} class="text-green mt-3 text-body-sm">
          Descrição salva.
        </p>

        <div class="mt-5 space-y-3">
          <form
            :for={f <- @folders}
            id={"folder-#{f.key}"}
            phx-submit="save_description"
            class="rounded-xl border border-white/8 bg-surface p-4"
          >
            <input type="hidden" name="key" value={f.key} />
            <div class="mb-2 flex items-center gap-2">
              <span class="size-3 rounded-full" style={"background:#{folder_color(f.key)}"} />
              <span class="text-body font-medium">{f.display_name}</span>
              <span class="text-ink-faint font-mono text-[11px]">{f.key}</span>
            </div>
            <textarea
              name="description"
              rows="3"
              class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
              placeholder="Descreva o que define esta pasta (estilo, época, instrumentação)…"
            >{f.description}</textarea>
            <div class="mt-2 flex justify-end">
              <button class="rounded-md bg-primary px-3 py-1.5 text-body-sm font-semibold text-white">
                Salvar
              </button>
            </div>
          </form>
        </div>
      </div>
    </.app_shell>
    """
  end
end
