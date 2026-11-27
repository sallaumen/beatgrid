const readingStates = {good: "Em ordem", watch: "Atenção", poor: "Rever", unknown: "Sem leitura"}
const listeningMessage = "Medindo a passagem."

// Renders only transport events. Audio frames never update the live region.
export function mountPassageScore(root) {
  const part = name => root.querySelector(`[data-score-${name}]`)
  const panel = part("panel"), total = part("total"), number = part("number")
  const scale = part("scale"), summary = part("summary"), metrics = part("metrics")
  const announce = part("announce"), template = part("template")
  let previous = null, disposed = false

  function reading(metric) {
    const row = template.content.firstElementChild.cloneNode(true)
    const state = row.querySelector("[data-reading-state]")
    row.querySelector("[data-reading-label]").textContent = metric.label
    row.querySelector("[data-reading-value]").textContent = metric.value
    state.dataset.state = metric.state
    state.textContent = readingStates[metric.state] ?? readingStates.unknown
    return row
  }

  function listening() {
    if (disposed) return
    previous = null
    panel.hidden = false
    total.hidden = metrics.hidden = true
    summary.textContent = listeningMessage
    if (announce.textContent !== listeningMessage) announce.textContent = listeningMessage
  }

  function show(result) {
    if (disposed || previous === result) return
    previous = result
    const scored = Number.isFinite(result.score)
    if (scored) {
      const digits = Array.from(String(result.score), digit => {
        const span = root.ownerDocument.createElement("span")
        span.dataset.scoreDigit = ""
        span.textContent = digit
        return span
      })
      number.replaceChildren(...digits)
    } else {
      number.textContent = "Sem nota"
    }

    panel.hidden = total.hidden = false
    scale.hidden = !scored
    summary.textContent = result.summary
    metrics.replaceChildren(...result.metrics.map(reading))
    metrics.hidden = result.metrics.length === 0
    const grade = scored ? `${result.score} de 100` : "Sem nota"
    announce.textContent = `Nota da passagem. ${grade}. ${result.summary}`
  }

  function clear() {
    panel.hidden = true
    previous = null
    if (announce.textContent) announce.textContent = ""
  }

  return {listening, show, clear, destroy() { clear(); disposed = true }}
}
