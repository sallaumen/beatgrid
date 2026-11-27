defmodule BeatgridWeb.GenresLive do
  @moduledoc """
  Manage the genre folders: create new ones, delete unused ones, and edit each
  folder's classification rubric (the description the AI uses to classify and to
  verify renames). AI drafts a separate rubric for review. Editing here
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
         editing: %{},
         creating: nil,
         return_focus: nil,
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
    case Enum.find(socket.assigns.folders, &(&1.key == key)) do
      nil ->
        {:noreply, socket}

      folder ->
        editor = %{
          description: folder.description || "",
          suggestion: nil,
          error: nil,
          request: nil
        }

        {:noreply,
         socket
         |> update(:editing, &Map.put_new(&1, key, editor))
         |> assign(toast: nil, return_focus: nil)}
    end
  end

  def handle_event("change_description", %{"key" => key, "description" => description}, socket) do
    {:noreply, update_editor(socket, key, &%{&1 | description: description})}
  end

  def handle_event("cancel_edit", %{"key" => key}, socket) do
    {:noreply, close_editor(socket, key) |> assign(toast: nil)}
  end

  def handle_event("save_description", %{"key" => key, "description" => description}, socket) do
    result =
      case GenreFolders.get_by_key(key) do
        nil -> {:error, :unknown_folder}
        folder -> GenreFolders.update(folder, %{description: description})
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> close_editor(key)
         |> assign_folders()
         |> assign(toast: {:saved, key})}

      {:error, _} ->
        {:noreply,
         update_editor(
           socket,
           key,
           &%{&1 | description: description, error: "Falha ao salvar. Tente novamente."}
         )}
    end
  end

  def handle_event("open_create", _params, socket) do
    {:noreply,
     assign(socket,
       creating: socket.assigns.creating || %{name: "", color: "#9498a6", error: nil},
       return_focus: nil,
       toast: nil
     )}
  end

  def handle_event("change_create", %{"display_name" => name, "color" => color}, socket) do
    {:noreply,
     update(socket, :creating, fn
       nil -> nil
       draft -> %{draft | name: name, color: color}
     end)}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, creating: nil, return_focus: :new, toast: nil)}
  end

  def handle_event("create_genre", %{"display_name" => name, "color" => color}, socket) do
    case GenreFolders.create_from_name(name, color) do
      {:ok, folder} ->
        {:noreply,
         socket
         |> assign_folders()
         |> assign(creating: nil, return_focus: :new, toast: {:created, folder.key})}

      {:error, reason} ->
        message =
          if reason == :invalid_name,
            do: "Informe um nome válido.",
            else: "Já existe um gênero com esse nome."

        {:noreply, assign(socket, creating: %{name: name, color: color, error: message})}
    end
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
    if Map.has_key?(socket.assigns.editing, key) do
      # The preview is transient and only belongs to this editing session.
      request = make_ref()

      {:noreply,
       socket
       |> update_editor(key, &%{&1 | request: request, error: nil})
       |> assign(suggesting: {key, request}, toast: nil)
       |> start_async({:suggest, key, request}, fn ->
         RecommendationAI.suggest_description(key)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply_suggestion", %{"key" => key}, socket) do
    {:noreply,
     update_editor(socket, key, fn
       %{suggestion: %RecommendationAI.Description{description: description}} = editor ->
         %{editor | description: description}

       editor ->
         editor
     end)}
  end

  defp close_editor(socket, key) do
    socket
    |> update(:editing, &Map.delete(&1, key))
    |> assign(return_focus: key)
  end

  defp update_editor(socket, key, fun) do
    if Map.has_key?(socket.assigns.editing, key),
      do: update(socket, :editing, &Map.update!(&1, key, fun)),
      else: socket
  end

  @impl true
  def handle_async(
        {:suggest, key, request},
        result,
        %{assigns: %{suggesting: {key, request}}} = socket
      ) do
    # A canceled or saved editor cannot be changed by an old response, even
    # when the user reopens the same genre before the original request finishes.
    socket =
      case socket.assigns.editing[key] do
        %{request: ^request} -> update_editor(socket, key, &suggestion_result(&1, result))
        _ -> socket
      end

    {:noreply, assign(socket, suggesting: nil)}
  end

  def handle_async({:suggest, _key, _request}, _result, socket), do: {:noreply, socket}

  defp suggestion_result(editor, {:ok, {:ok, %RecommendationAI.Description{} = suggestion}}),
    do: %{editor | suggestion: suggestion, request: nil}

  defp suggestion_result(editor, _result),
    do: %{editor | error: "Falha ao gerar a sugestão. Tente novamente.", request: nil}

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell flash={@flash} active={:generos} socket={@socket}>
      <header class="border-b border-white/6 bg-rail">
        <div class="mx-auto flex max-w-[1600px] flex-wrap items-center justify-between gap-3 px-3 py-3 sm:px-6">
          <div class="min-w-0">
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
        </div>
      </header>

      <div class="mx-auto max-w-[1600px] px-3 py-5 sm:px-6">
        <.toast toast={@toast} />

        <section>
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-[18px] font-semibold">
              Critérios por gênero
              <span class="font-mono text-body-lg font-normal text-ink-muted">{length(@folders)}</span>
            </h2>
            <button
              :if={is_nil(@creating)}
              id="open-new-genre"
              type="button"
              phx-click="open_create"
              phx-mounted={if @return_focus == :new, do: JS.focus()}
              class="inline-flex items-center gap-1.5 rounded-md border border-white/10 bg-input px-3 py-2 text-body font-medium text-ink-secondary hover:text-ink"
            >
              <.icon name="hero-plus" class="size-4" /> Novo gênero
            </button>
          </div>

          <form
            :if={@creating}
            id="new-genre"
            phx-change="change_create"
            phx-submit="create_genre"
            class="mt-3 grid gap-3 rounded-xl border border-white/8 bg-surface p-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
          >
            <div class="min-w-0">
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
                value={@creating.name}
                phx-mounted={JS.focus()}
                aria-label="Nome do novo gênero"
                aria-describedby={if @creating.error, do: "new-genre-error"}
                placeholder="Ex.: Forró Pé de Serra"
                class="w-full rounded-md border border-white/10 bg-input px-3 py-2.5 text-body sm:py-2"
              />
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <label class="flex items-center gap-2 text-body-sm text-ink-secondary">
                Cor
                <input
                  type="color"
                  name="color"
                  value={@creating.color}
                  aria-label="Cor do novo gênero"
                  class="size-10 shrink-0 cursor-pointer rounded-md border border-white/10 bg-input sm:size-9"
                />
              </label>
              <button
                type="button"
                phx-click="cancel_create"
                class="rounded-md px-3 py-2 text-body text-ink-secondary hover:bg-input"
              >Cancelar</button>
              <button class="rounded-md bg-primary-deep px-3 py-2.5 text-body font-semibold text-white hover:bg-primary-deep/90 sm:py-2">
                Criar gênero
              </button>
            </div>
            <p
              :if={@creating.error}
              id="new-genre-error"
              role="alert"
              class="text-body-sm text-coral sm:col-span-2"
            >
              {@creating.error}
            </p>
          </form>

          <p :if={@folders == []} class="mt-3 text-body text-ink-secondary">
            Nenhum gênero cadastrado.
          </p>

          <div class={[
            "mt-3 grid gap-3 lg:grid-cols-2 2xl:grid-cols-3",
            if(map_size(@editing) == 0, do: "items-stretch", else: "items-start")
          ]}>
            <article
              :for={f <- @folders}
              id={"genre-#{f.key}"}
              class="flex min-w-0 flex-col rounded-xl border border-white/8 bg-surface p-4"
            >
              <header class="flex items-start gap-2">
                <span
                  class="mt-1 size-3 shrink-0 rounded-full"
                  style={"background:#{folder_color(f.key)}"}
                  aria-hidden="true"
                />
                <h3 class="min-w-0 flex-1 break-words text-body-lg font-semibold text-ink">
                  {f.display_name}
                </h3>
                <span
                  :if={f.key in @in_use}
                  class="shrink-0 pt-0.5 text-body-sm text-ink-muted"
                  title="Mova as faixas antes de excluir."
                >
                  Em uso
                </span>
              </header>

              <%= if editor = @editing[f.key] do %>
                <form
                  id={"folder-#{f.key}"}
                  phx-change="change_description"
                  phx-submit="save_description"
                  class="mt-3 space-y-3"
                >
                  <input type="hidden" name="key" value={f.key} />
                  <div class="space-y-1">
                    <label
                      for={"description-#{f.key}"}
                      class="block text-body-sm font-medium text-ink-secondary"
                    >
                      Critério de classificação
                    </label>
                    <textarea
                      id={"description-#{f.key}"}
                      name="description"
                      phx-no-format
                      rows="8"
                      phx-mounted={JS.focus()}
                      aria-label={"Descrição de #{f.display_name}"}
                      class="block w-full resize-y rounded-md border border-white/10 bg-input px-3 py-2 text-body leading-relaxed"
                      placeholder="Descreva o que define esta pasta (estilo, época, instrumentação)…"
                    >{editor.description}</textarea>
                    <p :if={editor.error} role="alert" class="text-body-sm text-coral">
                      {editor.error}
                    </p>
                  </div>
                  <p role="status" class="sr-only">
                    {cond do
                      editor.request -> "Gerando rascunho com IA."
                      editor.suggestion -> "Rascunho da IA pronto para conferir."
                      true -> ""
                    end}
                  </p>
                  <div
                    :if={editor.suggestion}
                    id={"suggestion-#{f.key}"}
                    class="space-y-2 border-t border-white/8 pt-3"
                  >
                    <h4 class="text-body font-semibold text-primary">Rascunho da IA</h4>
                    <p
                      phx-no-format
                      class="whitespace-pre-wrap break-words text-body text-ink-secondary"
                    >{editor.suggestion.description}</p>
                    <p class="text-body-sm text-ink-muted">{editor.suggestion.rationale}</p>
                    <button
                      type="button"
                      id={"apply-suggestion-#{f.key}"}
                      phx-click={JS.focus() |> JS.push("apply_suggestion", value: %{key: f.key})}
                      class="rounded-md border border-white/10 bg-input px-3 py-2 text-body font-medium text-ink-secondary hover:text-ink"
                    >Substituir texto em edição</button>
                  </div>
                  <div class="flex flex-wrap items-center justify-end gap-2">
                    <button
                      type="button"
                      phx-click="suggest_description"
                      phx-value-key={f.key}
                      disabled={not is_nil(@suggesting)}
                      class="mr-auto rounded-md border border-primary/35 bg-primary/10 px-3 py-2 text-body font-medium text-primary hover:bg-primary/15 disabled:opacity-50"
                    >
                      {cond do
                        editor.request -> "Gerando rascunho…"
                        @suggesting -> "IA ocupada…"
                        true -> "Gerar rascunho com IA"
                      end}
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_edit"
                      phx-value-key={f.key}
                      class="rounded-md px-3 py-2 text-body text-ink-secondary hover:bg-input disabled:opacity-50"
                    >
                      Cancelar
                    </button>
                    <button class="rounded-md bg-primary-deep px-3 py-2 text-body font-semibold text-white hover:bg-primary-deep/90 disabled:opacity-50">
                      Salvar descrição
                    </button>
                  </div>
                </form>
              <% else %>
                <p
                  phx-no-format
                  class={[
                    "mt-3 mb-4 whitespace-pre-wrap break-words text-body leading-relaxed",
                    if(f.description in [nil, ""], do: "text-ink-muted", else: "text-ink-secondary")
                  ]}
                >{if f.description in [nil, ""], do: "Nenhum critério definido.", else: f.description}</p>
                <footer class="mt-auto flex flex-wrap items-center gap-2 border-t border-white/6 pt-3">
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
                    id={"edit-description-#{f.key}"}
                    phx-click="edit_description"
                    phx-value-key={f.key}
                    aria-label={"Editar descrição de #{f.display_name}"}
                    phx-mounted={if @return_focus == f.key, do: JS.focus()}
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
      <p :if={match?({:in_use, _}, @toast)} class="text-coral text-body">
        Gênero em uso — mova as faixas antes de excluir.
      </p>
      <p :if={match?({:error, _}, @toast)} class="text-coral text-body">
        Falha ao salvar. Tente novamente.
      </p>
    </div>
    """
  end
end
