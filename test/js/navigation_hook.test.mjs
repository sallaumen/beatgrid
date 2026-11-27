import assert from "node:assert/strict"
import test from "node:test"
import Navigation from "../../assets/js/navigation.js"

function fixture(t, {mobile = true, hasCurrent = true} = {}) {
  const browser = Object.assign(new EventTarget(), {
    location: {href: "https://beatgrid.test/ajustes"},
    requestAnimationFrame: callback => callback(),
  })
  const document = {
    activeElement: null,
    getElementById: id => id === "workspace-content" ? document.workspace : null,
  }
  const previousGlobals = {}
  for (const [key, value] of Object.entries({window: browser, document})) {
    previousGlobals[key] = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, {configurable: true, value})
  }

  const focusable = () => ({
    focus(options) {
      document.activeElement = this
      this.focusOptions = options
    },
  })
  document.workspace = focusable()
  const toggle = Object.assign(focusable(), {
    expanded: "false",
    setAttribute(name, value) { if (name === "aria-expanded") this.expanded = value },
    getClientRects: () => mobile ? [{}] : [],
    closest: selector => selector === "#mobile-nav-toggle" ? toggle : null,
  })
  const panel = {
    scrollTop: 0,
    clientTop: 0,
    clientHeight: 200,
    getBoundingClientRect: () => ({top: 100, bottom: 300}),
    querySelector: selector => selector === "a[aria-current=page]" ? (hasCurrent ? current : null) : first,
  }
  const link = (href, top) => {
    const element = Object.assign(focusable(), {
      href,
      closest: selector => selector === "#app-destinations a[href]" ? element : null,
      getBoundingClientRect: () => ({top: top - panel.scrollTop, bottom: top + 44 - panel.scrollTop}),
    })
    return element
  }
  const first = link("https://beatgrid.test/", 120)
  const current = link("https://beatgrid.test/ajustes", 320)
  const nav = Object.assign(new EventTarget(), {
    querySelector: selector => selector === "#mobile-nav-toggle" ? toggle : panel,
    contains: node => [toggle, first, current].includes(node),
  })
  const hook = Object.assign(Object.create(Navigation), {el: nav})
  hook.mounted()
  t.after(() => {
    hook.destroyed()
    for (const [key, previous] of Object.entries(previousGlobals)) {
      if (previous) Object.defineProperty(globalThis, key, previous)
      else delete globalThis[key]
    }
  })

  const click = (target, modifiers = {}) => {
    const event = new Event("click", {cancelable: true})
    Object.defineProperties(event, {
      target: {value: target},
      button: {value: 0},
      ...Object.fromEntries(Object.entries(modifiers).map(([key, value]) => [key, {value}])),
    })
    nav.dispatchEvent(event)
  }
  const escape = () => {
    const event = new Event("keydown", {cancelable: true})
    Object.defineProperty(event, "key", {value: "Escape"})
    browser.dispatchEvent(event)
    return event
  }
  const navigate = (href, pop = false) =>
    browser.dispatchEvent(new CustomEvent("phx:navigate", {detail: {href, pop}}))

  return {browser, document, hook, toggle, panel, current, first, click, escape, navigate, focusable}
}

test("opening focuses the current destination and reveals it inside the menu only", t => {
  const {document, hook, toggle, panel, current, click, escape} = fixture(t)
  click(toggle)
  assert.equal(toggle.expanded, "true")
  assert.equal(document.activeElement, current)
  assert.deepEqual(current.focusOptions, {preventScroll: true})
  assert.equal(panel.scrollTop, 64)

  // LiveView may patch the original aria-expanded attribute while the menu is open.
  toggle.expanded = "false"
  hook.updated()
  assert.equal(toggle.expanded, "true")

  assert.ok(escape().defaultPrevented)
  assert.equal(toggle.expanded, "false")
  assert.equal(document.activeElement, toggle)
  assert.deepEqual(toggle.focusOptions, {preventScroll: true})
  assert.equal(panel.scrollTop, 64)
})

test("when no route is current, opening reaches the first destination without changing scroll", t => {
  const {document, toggle, panel, first, click} = fixture(t, {hasCurrent: false})
  click(toggle)
  assert.equal(document.activeElement, first)
  assert.equal(panel.scrollTop, 0)
  click(toggle)
  assert.equal(toggle.expanded, "false")
  assert.equal(document.activeElement, toggle)
})

test("selecting a destination closes the menu and focuses the new workspace after navigation", t => {
  const {document, hook, toggle, first, click, navigate, focusable} = fixture(t)
  click(toggle)
  click(first)
  assert.equal(toggle.expanded, "false")
  assert.equal(document.activeElement, toggle)
  hook.destroyed()
  document.workspace = focusable()
  navigate(first.href)
  assert.equal(document.activeElement, document.workspace)
  assert.deepEqual(document.workspace.focusOptions, {preventScroll: true})
})

test("opening a destination in another tab preserves the mobile menu", t => {
  const {document, toggle, current, first, click} = fixture(t)
  click(toggle)
  click(first, {metaKey: true})
  click(first, {ctrlKey: true})
  assert.equal(toggle.expanded, "true")
  assert.equal(document.activeElement, current)
})

test("Escape outside an open menu closes it without stealing focus", t => {
  const {document, toggle, click, escape} = fixture(t)
  click(toggle)
  document.workspace.focus()
  assert.equal(escape().defaultPrevented, false)
  assert.equal(toggle.expanded, "false")
  assert.equal(document.activeElement, document.workspace)
})

test("a history event never forces focus onto the destination", t => {
  const {document, toggle, first, click, navigate} = fixture(t)
  click(toggle)
  click(first)
  navigate(first.href, true)
  assert.equal(document.activeElement, toggle)
})

test("desktop activation and Escape do not change focus", t => {
  const {document, toggle, first, click, escape} = fixture(t, {mobile: false})
  click(toggle)
  click(first)
  assert.equal(toggle.expanded, "false")
  assert.equal(document.activeElement, null)
  assert.equal(escape().defaultPrevented, false)
})
