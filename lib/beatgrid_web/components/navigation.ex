defmodule BeatgridWeb.Navigation do
  @moduledoc "Task-based destinations shared by the expanded, compact and mobile menus."
  use BeatgridWeb, :html

  attr :active, :atom, required: true

  def menu(assigns) do
    ~H"""
    <nav
      id="app-navigation"
      phx-hook=".NavigationMenu"
      aria-label="Navegação principal"
      class="group/nav flex w-full shrink-0 flex-col border-b border-white/6 bg-rail px-3 py-1 md:sticky md:top-0 md:h-dvh md:w-[216px] md:gap-3 md:border-r md:border-b-0 md:pt-4 md:pb-20 md:motion-safe:transition-[width] md:motion-safe:duration-200 md:motion-safe:ease-out md:nav-collapsed:w-[88px] md:nav-collapsed:px-2"
    >
      <div class="flex items-center gap-2.5 px-1 md:nav-collapsed:justify-center md:nav-collapsed:px-0">
        <img
          src="/images/logo.svg"
          alt=""
          width="36"
          height="36"
          class="size-6 shrink-0 md:size-9"
        />
        <span class="flex-1 truncate text-[15px] font-semibold tracking-tight md:nav-collapsed:hidden">
          Beatgrid
        </span>
        <button
          id="mobile-nav-toggle"
          type="button"
          aria-expanded="false"
          aria-controls="app-destinations"
          class="flex min-h-11 items-center gap-2 rounded-md px-2 text-body font-medium text-ink-secondary hover:bg-white/5 md:hidden"
        >
          <span class="hero-bars-3 size-4" aria-hidden="true" /> Menu
        </button>
        <button
          type="button"
          data-nav-toggle
          aria-label="Recolher menu lateral"
          class="hidden size-7 shrink-0 md:flex items-center justify-center rounded-md text-ink-faint transition-colors hover:bg-white/5 hover:text-ink md:nav-collapsed:hidden"
        >
          <span class="hero-chevron-double-left size-4" aria-hidden="true" />
        </button>
      </div>

      <button
        type="button"
        data-nav-toggle
        aria-label="Expandir menu lateral"
        class="mx-auto hidden size-7 items-center justify-center rounded-md text-ink-faint transition-colors hover:bg-white/5 hover:text-ink md:nav-collapsed:flex"
      >
        <span class="hero-chevron-double-right size-4" aria-hidden="true" />
      </button>

      <div
        id="app-destinations"
        class="hidden max-h-[55dvh] grid-cols-2 gap-3 overflow-y-auto border-t border-white/6 py-2 group-has-[[aria-expanded=true]]/nav:grid md:flex md:min-h-0 md:max-h-none md:flex-col md:gap-3 md:overflow-y-auto md:border-0 md:py-0"
      >
        <div
          :for={section <- sections()}
          role="group"
          aria-label={section.title}
          class="flex min-w-0 flex-col gap-0.5"
        >
          <p class="px-2 pb-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-ink-faint md:nav-collapsed:hidden">
            {section.title}
          </p>
          <div
            class="mx-auto my-1 hidden h-px w-7 rounded-full bg-white/8 md:nav-collapsed:block"
            aria-hidden="true"
          />
          <.nav_item :for={item <- section.items} item={item} active={@active == item.key} />
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".NavigationMenu">
        import NavigationMenu from "@/js/navigation.js"
        export default NavigationMenu
      </script>
    </nav>
    """
  end

  defp sections do
    [
      %{
        title: "Coleção",
        items: [
          %{
            key: :biblioteca,
            label: "Biblioteca",
            short: "Biblioteca",
            icon: "hero-musical-note",
            href: ~p"/"
          },
          %{
            key: :importados,
            label: "Importações",
            short: "Importar",
            icon: "hero-arrow-down-tray",
            href: ~p"/importados"
          },
          %{
            key: :painel,
            label: "Repertório",
            short: "Repertório",
            icon: "hero-chart-bar",
            href: ~p"/painel"
          }
        ]
      },
      %{
        title: "Curadoria",
        items: [
          %{
            key: :revisao,
            label: "Revisão de sugestões",
            short: "Revisão",
            icon: "hero-clipboard-document-check",
            href: ~p"/revisao"
          },
          %{
            key: :dedup,
            label: "Duplicatas",
            short: "Duplicatas",
            icon: "hero-document-duplicate",
            href: ~p"/dedup"
          },
          %{
            key: :generos,
            label: "Gêneros",
            short: "Gêneros",
            icon: "hero-tag",
            href: ~p"/generos"
          },
          %{
            key: :resgate,
            label: "Recuperação de arquivos",
            short: "Recuperação",
            icon: "hero-lifebuoy",
            href: ~p"/resgate"
          }
        ]
      },
      %{
        title: "Sets e palco",
        items: [
          %{
            key: :sets,
            label: "Montagem de sets",
            short: "Montagem",
            icon: "hero-queue-list",
            href: ~p"/set"
          },
          %{
            key: :mixes,
            label: "Sets gravados",
            short: "Gravados",
            icon: "hero-rectangle-stack",
            href: ~p"/sets-online"
          },
          %{
            key: :discotecagem,
            label: "Discotecagem",
            short: "Decks",
            icon: "hero-adjustments-vertical",
            href: ~p"/discotecagem"
          }
        ]
      },
      %{
        title: "Sistema",
        items: [
          %{
            key: :jobs,
            label: "Fila de tarefas",
            short: "Fila",
            icon: "hero-clock",
            href: ~p"/jobs"
          },
          %{
            key: :manutencao,
            label: "Manutenção",
            short: "Manutenção",
            icon: "hero-wrench-screwdriver",
            href: ~p"/manutencao"
          },
          %{
            key: :ajustes,
            label: "Ajustes",
            short: "Ajustes",
            icon: "hero-cog-6-tooth",
            href: ~p"/ajustes"
          }
        ]
      }
    ]
  end

  attr :item, :map, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@item.href}
      title={@item.label}
      aria-label={@item.label}
      aria-current={@active && "page"}
      class={[
        "flex min-h-11 items-center gap-3 md:min-h-0 rounded-lg px-2.5 py-2 transition-colors",
        "md:nav-collapsed:flex-col md:nav-collapsed:gap-0.5 md:nav-collapsed:px-0.5 md:nav-collapsed:py-1.5",
        @active && "bg-primary/12 text-primary",
        !@active && "text-ink-muted hover:bg-white/5 hover:text-ink"
      ]}
    >
      <span class={[@item.icon, "size-5 shrink-0"]} aria-hidden="true" />
      <span class={[
        "min-w-0 text-body-lg leading-tight tracking-tight md:nav-collapsed:hidden",
        if(@active, do: "font-semibold", else: "font-medium")
      ]}>
        {@item.label}
      </span>
      <span class="hidden text-caption font-medium leading-tight md:nav-collapsed:block">
        {@item.short}
      </span>
    </.link>
    """
  end
end
