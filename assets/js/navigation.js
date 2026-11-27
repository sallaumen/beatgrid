// Mobile disclosure only. Desktop rail sizing and persistence are owned by the
// root layout; LiveView remains responsible for history and page scroll.
let pendingDestination = null

function focusWorkspace(event) {
  const destination = pendingDestination
  pendingDestination = null

  if (!destination || event.detail?.pop || event.detail?.href !== destination) return

  window.requestAnimationFrame(() => {
    document.getElementById("workspace-content")?.focus({preventScroll: true})
  })
}

function revealWithinPanel(panel, item) {
  const top = panel.getBoundingClientRect().top + panel.clientTop
  const bottom = top + panel.clientHeight
  const bounds = item.getBoundingClientRect()

  if (bounds.top < top) panel.scrollTop += bounds.top - top
  else if (bounds.bottom > bottom) panel.scrollTop += bounds.bottom - bottom
}

export default {
  mounted() {
    this.open = false
    this.updated()

    this.onClick = event => {
      if (!this.isMobile()) return

      if (event.target.closest("#mobile-nav-toggle")) {
        this.setOpen(!this.open)
        if (this.open) {
          const destination = this.panel.querySelector("a[aria-current=page]") ||
            this.panel.querySelector("a[href]")
          if (destination) {
            destination.focus({preventScroll: true})
            revealWithinPanel(this.panel, destination)
          }
        } else {
          this.toggle.focus({preventScroll: true})
        }
        return
      }

      const link = event.target.closest("#app-destinations a[href]")
      if (!this.open || !link || event.defaultPrevented ||
          event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

      // Do not leave focus on a now-hidden link during the route change.
      this.setOpen(false)
      this.toggle.focus({preventScroll: true})
      pendingDestination = link.href
      // A navigation destroys this hook before phx:navigate, so keep a single
      // one-shot handler across the remount. Leave back/forward scrolling alone.
      window.addEventListener("phx:navigate", focusWorkspace, {once: true})
    }

    this.onKeyDown = event => {
      if (event.key !== "Escape" || event.defaultPrevented || !this.open || !this.isMobile()) return

      const focusInNavigation = this.el.contains(document.activeElement)
      this.setOpen(false)
      if (focusInNavigation) {
        event.preventDefault()
        this.toggle.focus({preventScroll: true})
      }
    }

    this.el.addEventListener("click", this.onClick)
    window.addEventListener("keydown", this.onKeyDown)
  },

  updated() {
    this.toggle = this.el.querySelector("#mobile-nav-toggle")
    this.panel = this.el.querySelector("#app-destinations")
    this.setOpen(this.open)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("keydown", this.onKeyDown)
  },

  isMobile() {
    return this.toggle.getClientRects().length > 0
  },

  setOpen(open) {
    this.open = open
    this.toggle.setAttribute("aria-expanded", String(open))
  },
}
