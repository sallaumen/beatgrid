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
    {:ok,
     assign_folders(
       assign(socket,
         page_title: "Gêneros",
         toast: nil,
         editing: MapSet.new(),
         ai_fill: %{},
         suggesting: nil
       )
     )}
  end

  # Folders + their in-use flags in one place: the flags come as ONE set (two
  # queries total), not two queries per card per render.
  defp assign_folders(socket),
    do: assign(socket, folders: GenreFolders.list(), in_use: GenreFolders.in_use_keys())

  @impl true
  def handle_event("edit_description", %{"key" => key}, socket) do
    {:noreply, update(socket, :editing, &MapSet.put(&1, key))}
  end

  def handle_event("cancel_edit", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> update(:editing, &MapSet.delete(&1, key))
     |> update(:ai_fill, &Map.delete(&1, key))
     |> assign(toast: nil)}
  end

  def handle_event("save_description", %{"key" => key, "description" => description}, socket) do
    toast =
      case GenreFolders.get_by_key(key) do
        nil ->
          {:error, :unknown_folder}

        folder ->
          with {:ok, _} <- GenreFolders.update(folder, %{description: description}),
               do: {:saved, key}
      end

    socket = socket |> assign_folders() |> assign(toast: toast)

    socket =
      case toast do
        {:saved, ^key} ->
          socket
          |> update(:editing, &MapSet.delete(&1, key))
          |> update(:ai_fill, &Map.delete(&1, key))

        _ ->
          socket
      end

    {:noreply, socket}
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

  def handle_event("suggest_description", _params, %{assigns: %{suggesting: key}} = socket)
      when not is_nil(key), do: {:noreply, socket}

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
      <header class="flex flex-wrap items-center justify-between gap-3 border-b border-white/6 bg-rail px-6 py-3">
        <div>
          <h1 class="text-[22px] font-semibold">Gêneros</h1>
          <p class="text-body-sm text-ink-muted">
            As descrições orientam a IA ao sugerir pastas e conferir nomes de faixas.
          </p>
        </div>
        <.link
          navigate={~p"/revisao?aba=classifications"}
          class="text-body-sm text-primary hover:underline"
        >
          Revisar classificações
        </.link>
      </header>

      <div class="mx-auto max-w-[1600px] px-4 py-5 sm:px-6">
        <.toast toast={@toast} />

        <form
          id="new-genre"
          phx-submit="create_genre"
          class="flex flex-col gap-2 rounded-xl border border-white/8 bg-surface p-4 sm:flex-row sm:items-end"
        >
          <div class="min-w-0 flex-1">
            <label
              for="new-genre-name"
              class="mb-1 block text-body-sm font-semibold text-ink-secondary"
            >
              Novo gênero
            </label>
            <input
              id="new-genre-name"
              name="display_name"
              required
              aria-label="Nome do novo gênero"
              placeholder="Ex.: Forró Pé de Serra"
              class="w-full rounded-md border border-white/10 bg-input px-3 py-2.5 text-body sm:py-2"
            />
          </div>
          <div class="flex items-center justify-between gap-3">
            <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
              Cor
              <input
                type="color"
                name="color"
                value="#9498a6"
                aria-label="Cor do novo gênero"
                class="size-10 shrink-0 cursor-pointer rounded-md border border-white/10 bg-input sm:size-9"
              />
            </label>
            <button class="rounded-md bg-primary-deep px-3 py-2.5 text-body font-semibold text-white hover:bg-primary-deep/90 sm:py-2">
              Criar gênero
            </button>
          </div>
        </form>

        <section class="mt-6">
          <h2 class="text-[18px] font-semibold">
            Critérios por gênero
            <span class="font-mono text-body-lg font-normal text-ink-muted">{length(@folders)}</span>
          </h2>

          <p :if={@folders == []} class="mt-3 text-body text-ink-secondary">
            Nenhum gênero cadastrado.
          </p>

          <div class="mt-3 grid items-start gap-3 lg:grid-cols-2">
            <article
              :for={f <- @folders}
              id={"genre-#{f.key}"}
              class="min-w-0 rounded-xl border border-white/8 bg-surface p-4"
            >
              <header class="flex flex-wrap items-center gap-2">
                <span
                  class="size-3 shrink-0 rounded-full"
                  style={"background:#{folder_color(f.key)}"}
                  aria-hidden="true"
                />
                <h3 class="min-w-0 break-words text-body-lg font-semibold text-ink">
                  {f.display_name}
                </h3>
                <span
                  :if={f.key in @in_use}
                  class="ml-auto text-body-sm text-ink-muted"
                  title="Mova as faixas antes de excluir."
                >
                  Em uso
                </span>
              </header>

              <%= if MapSet.member?(@editing, f.key) do %>
                <form id={"folder-#{f.key}"} phx-submit="save_description" class="mt-3 space-y-3">
                  <input type="hidden" name="key" value={f.key} />
                  <label
                    for={"description-#{f.key}"}
                    class="block text-body-sm font-medium text-ink-secondary"
                  >
                    Critério de classificação
                  </label>
                  <textarea
                    id={"description-#{f.key}"}
                    name="description"
                    rows="8"
                    aria-label={"Descrição de #{f.display_name}"}
                    class="w-full resize-y rounded-md border border-white/10 bg-input px-3 py-2 text-body leading-relaxed"
                    placeholder="Descreva o que define esta pasta (estilo, época, instrumentação)…"
                  >{Map.get(@ai_fill, f.key, f.description)}</textarea>
                  <div class="flex flex-wrap items-center justify-end gap-2">
                    <button
                      type="button"
                      phx-click="suggest_description"
                      phx-value-key={f.key}
                      disabled={not is_nil(@suggesting)}
                      class="mr-auto rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body font-medium text-primary hover:bg-primary/15 disabled:opacity-50"
                    >
                      {if @suggesting == f.key, do: "Gerando rascunho…", else: "Gerar rascunho com IA"}
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      phx-value-key={f.key}
                      disabled={@suggesting == f.key}
                      class="rounded-md px-3 py-2 text-body text-ink-secondary hover:bg-input disabled:opacity-50"
                    >
                      Cancelar
                    </button>
                    <button
                      disabled={@suggesting == f.key}
                      class="rounded-md bg-primary-deep px-3 py-2 text-body font-semibold text-white hover:bg-primary-deep/90 disabled:opacity-50"
                    >
                      Salvar descrição
                    </button>
                  </div>
                </form>
              <% else %>
                <p class={[
                  "mt-3 whitespace-pre-wrap break-words text-body leading-relaxed",
                  if(f.description in [nil, ""], do: "text-ink-muted", else: "text-ink-secondary")
                ]}>
                  {if f.description in [nil, ""], do: "Nenhum critério definido.", else: f.description}
                </p>
                <footer class="mt-4 flex flex-wrap items-center gap-2 border-t border-white/6 pt-3">
                  <button
                    :if={f.key not in @in_use}
                    type="button"
                    phx-click="delete_genre"
                    phx-value-key={f.key}
                    data-confirm={"Excluir o gênero “#{f.display_name}”? Esta ação não pode ser desfeita."}
                    class="rounded-md px-3 py-2 text-body text-coral hover:bg-coral/10"
                  >
                    Excluir
                  </button>
                  <button
                    type="button"
                    phx-click="edit_description"
                    phx-value-key={f.key}
                    aria-label={"Editar descrição de #{f.display_name}"}
                    class="ml-auto inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-input px-3 py-2 text-body font-medium text-ink-secondary hover:text-ink"
                  >
                    <.icon name="hero-pencil-square" class="size-4" /> Editar descrição
                  </button>
                </footer>
              <% end %>
            </article>
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end

  attr :toast, :any, default: nil

  defp toast(assigns) do
    ~H"""
    <div :if={@toast} role="status" class="mb-3">
      <p :if={match?({:saved, _}, @toast)} class="text-green text-body">
        Descrição salva.
      </p>
      <p :if={match?({:created, _}, @toast)} class="text-green text-body">
        Gênero criado.
      </p>
      <p :if={match?({:deleted, _}, @toast)} class="text-green text-body">
        Gênero excluído.
      </p>
      <p :if={match?({:suggested, _}, @toast)} class="text-green text-body">
        Sugestão pronta — revise e salve. {elem(@toast, 1)}
      </p>
      <p :if={match?({:in_use, _}, @toast)} class="text-coral text-body">
        Gênero em uso — mova as faixas antes de excluir.
      </p>
      <p :if={match?({:create_error, _}, @toast)} class="text-coral text-body">
        {elem(@toast, 1)}
      </p>
      <p :if={match?({:suggest_error, _}, @toast)} class="text-coral text-body">
        Falha ao gerar a sugestão. Tente novamente.
      </p>
      <p :if={match?({:error, _}, @toast)} class="text-coral text-body">
        Falha ao salvar. Tente novamente.
      </p>
    </div>
    """
  end
end
