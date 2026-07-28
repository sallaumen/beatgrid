defmodule BeatgridWeb.GenresLive do
  @moduledoc """
  Manage the genre folders: create new ones, delete unused ones, and edit each
  folder's classification rubric (the description the AI uses to classify and to
  verify renames). "Preencher com IA" drafts a rubric for review. Editing here
  improves every AI pass.
  """
  use BeatgridWeb, :live_view

  import BeatgridWeb.UI

  alias Beatgrid.Library.GenreFolders
  alias Beatgrid.Repertoire.RecommendationAI

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_folders(assign(socket, toast: nil, ai_fill: %{}, suggesting: nil))}
  end

  # Folders + their in-use flags in one place: the flags come as ONE set (two
  # queries total), not two queries per card per render.
  defp assign_folders(socket),
    do: assign(socket, folders: GenreFolders.list(), in_use: GenreFolders.in_use_keys())

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

    {:noreply,
     socket
     |> assign_folders()
     |> assign(
       toast: toast,
       ai_fill: Map.delete(socket.assigns.ai_fill, key)
     )}
  end

  def handle_event("create_genre", %{"display_name" => display_name} = params, socket) do
    toast =
      case GenreFolders.create_from_name(display_name, params["color"]) do
        {:ok, folder} -> {:created, folder.key}
        {:error, :invalid_name} -> {:create_error, "Informe um nome válido."}
        {:error, _changeset} -> {:create_error, "Já existe um gênero com esse nome."}
      end

    {:noreply, socket |> assign_folders() |> assign(toast: toast)}
  end

  def handle_event("delete_genre", %{"key" => key}, socket) do
    toast =
      case GenreFolders.get_by_key(key) do
        nil ->
          {:error, :unknown_folder}

        folder ->
          case GenreFolders.delete(folder) do
            {:ok, _} -> {:deleted, key}
            {:error, :in_use} -> {:in_use, key}
          end
      end

    {:noreply, socket |> assign_folders() |> assign(toast: toast)}
  end

  def handle_event("suggest_description", %{"key" => key}, socket) do
    # Intentionally NOT an Oban job: the draft only feeds this form field — if the
    # tab dies, nothing is lost and the user just clicks again.
    {:noreply,
     socket
     |> assign(suggesting: key, toast: nil)
     |> start_async({:suggest, key}, fn -> RecommendationAI.suggest_description(key) end)}
  end

  @impl true
  def handle_async({:suggest, key}, {:ok, {:ok, %RecommendationAI.Description{} = desc}}, socket) do
    {:noreply,
     assign(socket,
       suggesting: nil,
       ai_fill: Map.put(socket.assigns.ai_fill, key, desc.description),
       toast: {:suggested, desc.rationale}
     )}
  end

  def handle_async({:suggest, _key}, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, suggesting: nil, toast: {:suggest_error, inspect(reason)})}
  end

  def handle_async({:suggest, _key}, {:exit, reason}, socket) do
    {:noreply, assign(socket, suggesting: nil, toast: {:suggest_error, inspect(reason)})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:generos} socket={@socket}>
      <header class="border-b border-white/6 bg-rail px-6 py-3">
        <h2 class="text-[22px] font-semibold">Gêneros</h2>
        <p class="text-ink-muted text-body-sm">
          A descrição de cada pasta é o contexto que a IA usa pra classificar e pra verificar os
          renomes. Quanto melhor a descrição, mais espertas as sugestões.
        </p>
      </header>

      <div class="mx-auto max-w-[1600px] px-6 py-6">
        <.toast toast={@toast} />

        <form
          id="new-genre"
          phx-submit="create_genre"
          class="mt-5 flex items-end gap-2 rounded-xl border border-white/8 bg-surface p-4"
        >
          <div class="flex-1">
            <label class="text-ink-muted mb-1 block text-[11px] font-semibold uppercase tracking-wide">
              Novo gênero
            </label>
            <input
              name="display_name"
              required
              placeholder="Ex.: Forró Pé de Serra"
              class="w-full rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
            />
          </div>
          <input
            type="color"
            name="color"
            value="#9498a6"
            class="size-9 shrink-0 cursor-pointer rounded-md border border-white/8 bg-input"
            title="Cor"
          />
          <button class="rounded-md bg-primary px-3 py-2 text-body-sm font-semibold text-white">
            Criar
          </button>
        </form>

        <div class="mt-5 grid gap-4 lg:grid-cols-2 2xl:grid-cols-3">
          <form
            :for={f <- @folders}
            id={"folder-#{f.key}"}
            phx-submit="save_description"
            class="flex flex-col rounded-xl border border-white/8 bg-surface p-4"
          >
            <input type="hidden" name="key" value={f.key} />
            <div class="mb-2 flex items-center gap-2">
              <span class="size-3 shrink-0 rounded-full" style={"background:#{folder_color(f.key)}"} />
              <span class="min-w-0 truncate text-body font-medium">{f.display_name}</span>
              <span class="text-ink-faint shrink-0 font-mono text-[11px]">{f.key}</span>
              <div class="ml-auto flex items-center gap-2">
                <button
                  type="button"
                  phx-click="suggest_description"
                  phx-value-key={f.key}
                  disabled={@suggesting == f.key}
                  class="rounded-md bg-primary/15 px-2.5 py-1 text-[12px] font-semibold text-primary hover:bg-primary/25 disabled:opacity-50"
                >
                  {if @suggesting == f.key, do: "Preenchendo…", else: "Preencher com IA"}
                </button>
                <button
                  :if={f.key not in @in_use}
                  type="button"
                  phx-click="delete_genre"
                  phx-value-key={f.key}
                  data-confirm={"Excluir o gênero “#{f.display_name}”? Esta ação não pode ser desfeita."}
                  class="rounded-md bg-coral/10 px-2.5 py-1 text-[12px] font-semibold text-coral hover:bg-coral/20"
                >
                  Excluir
                </button>
                <span
                  :if={f.key in @in_use}
                  class="text-ink-faint text-[11px]"
                  title="Mova as faixas antes de excluir."
                >
                  Em uso
                </span>
              </div>
            </div>
            <textarea
              name="description"
              rows="4"
              class="w-full flex-1 rounded-md border border-white/8 bg-input px-3 py-2 text-body-sm focus:border-primary/50 focus:outline-none"
              placeholder="Descreva o que define esta pasta (estilo, época, instrumentação)…"
            >{Map.get(@ai_fill, f.key, f.description)}</textarea>
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

  attr :toast, :any, default: nil

  defp toast(assigns) do
    ~H"""
    <p :if={match?({:saved, _}, @toast)} class="text-green mt-3 text-body-sm">
      Descrição salva.
    </p>
    <p :if={match?({:created, _}, @toast)} class="text-green mt-3 text-body-sm">
      Gênero criado.
    </p>
    <p :if={match?({:deleted, _}, @toast)} class="text-green mt-3 text-body-sm">
      Gênero excluído.
    </p>
    <p :if={match?({:suggested, _}, @toast)} class="text-green mt-3 text-body-sm">
      Sugestão pronta — revise e salve. {elem(@toast, 1)}
    </p>
    <p :if={match?({:in_use, _}, @toast)} class="text-coral mt-3 text-body-sm">
      Gênero em uso — mova as faixas antes de excluir.
    </p>
    <p :if={match?({:create_error, _}, @toast)} class="text-coral mt-3 text-body-sm">
      {elem(@toast, 1)}
    </p>
    <p :if={match?({:suggest_error, _}, @toast)} class="text-coral mt-3 text-body-sm">
      Falha ao gerar a sugestão. Tente novamente.
    </p>
    <p :if={match?({:error, _}, @toast)} class="text-coral mt-3 text-body-sm">
      Falha ao salvar. Tente novamente.
    </p>
    """
  end
end
