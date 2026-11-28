// Compare the sound that was heard. The headphone pan and transition kind are
// intentionally outside the identity. The latter selects one of the two takes.
export function rehearsalKey(pair, plan, bpm, curve = plan?.blendCurve) {
  if (!plan) return null
  const controls = ({rate, vinyl, filter, tone, level}) => [rate, vinyl, filter, tone, level]
  return JSON.stringify([pair.from, pair.to, pair.fromLoad, pair.toLoad, bpm, plan.exit, plan.inStart,
    plan.lead, plan.blend, plan.duration, controls(plan.mix.out), controls(plan.mix.into), curve ?? null])
}

function scoreLabel(result, unavailable) {
  if (!result) return unavailable ? "Sem medição" : "Falta ouvir"
  return result.score == null ? "Sem nota" : `${result.score}/100`
}

function differences(first, second) {
  if (!first || !second) return []
  return first.metrics.flatMap(a => {
    const b = second.metrics.find(m => m.id === a.id)
    if (!b || a.state === "unknown" || b.state === "unknown") return []
    if (a.id === "headroom" && a.finding !== b.finding) return [] // dBTP and dBFS are different measurements.
    if (a.state === b.state && (a.state === "good" || a.finding === b.finding)) return []
    return [{first: a, second: b}]
  })
}

function comparisonSummary(rows, kinds, name) {
  if (rows.length === 1 && rows[0].first.id === "level") {
    const levels = [rows[0].first, rows[0].second]
    const dip = levels.findIndex(m => m.finding === "dip" && m.state === "poor")
    if (dip >= 0 && levels[1 - dip].state === "good") {
      return name(kinds[1 - dip], true) + " sustentou melhor o volume no meio da passagem."
    }
  }
  const metrics = rows.map(({first}) => first.label.toLocaleLowerCase("pt-BR"))
  return "Há diferenças de " + new Intl.ListFormat("pt-BR").format(metrics) + "."
}

export function mountPassageComparison(details, labels, selected, name, showDifferences = () => {}) {
  const heard = new Map()
  const unavailable = new Set()
  let key = null, settingsKey = null, active = null, pairSummary = ""
  let lastPair, lastPlan, lastBpm

  function render(restored, showDetail = true) {
    for (const label of labels) {
      const kind = label.dataset.scoreFor
      label.hidden = !heard.size && !unavailable.size
      label.textContent = scoreLabel(heard.get(kind), unavailable.has(kind))
    }
    if (!showDetail) return
    const kind = selected()
    const reference = {pair: name(kind)}
    const current = heard.get(kind)
    if (unavailable.has(kind)) {
      const summary = current ? "Medição incompleta. A leitura é do ensaio anterior." :
        "Não foi possível medir esta reprodução inteira."
      const retained = {score: current?.score ?? null, metrics: current?.metrics ?? [], summary}
      details.show(retained, {reference, restored: true, announcement: restored ? "" : summary})
    } else if (current) details.show(current, {reference, restored})
    else details.clear()
  }

  function clearSummary() {
    if (pairSummary) showDifferences(null)
    pairSummary = ""
  }

  function select() {
    active = null
    clearSummary()
    render(true)
  }

  function bind(pair, plan, bpm) {
    // Memoize polling without keeping the decoded tracks alive after the dialog closes.
    const samePlan = plan ? lastPlan?.deref() === plan : lastPlan === null
    if (pair === lastPair && samePlan && bpm === lastBpm) return
    lastPair = pair
    lastPlan = plan ? new WeakRef(plan) : null
    lastBpm = bpm
    const next = rehearsalKey(pair, plan, bpm)
    if (next === key) return
    key = next
    settingsKey = plan?.blendCurve ? rehearsalKey(pair, plan, bpm, null) : next
    heard.clear()
    unavailable.clear()
    select()
  }

  function begin(kind) {
    clearSummary()
    const take = {
      finish(result) {
        if (active !== take) return
        active = null
        heard.set(kind, result)
        unavailable.delete(kind)
        render(false, kind === selected())
      },
      unavailable() {
        if (active !== take) return
        active = null
        unavailable.add(kind)
        render(false, kind === selected())
      },
      cancel() {
        if (active === take) select()
      }
    }
    active = take
    if (kind === selected()) details.listening()
    return take
  }

  function finishPair(kinds) {
    pairSummary = kinds.map(kind => {
      const value = unavailable.has(kind) ? "sem medição" : scoreLabel(heard.get(kind), false).toLowerCase()
      return name(kind) + " " + value
    }).join(" · ") + "."
    const rows = differences(...kinds.map(kind => unavailable.has(kind) ? null : heard.get(kind)))
    if (rows.length) pairSummary += " " + comparisonSummary(rows, kinds, name)
    showDifferences(rows.length ? {names: kinds.map(kind => name(kind, true)), rows} : null)
  }

  function reading() {
    const kind = selected()
    return unavailable.has(kind) ? null : heard.get(kind) ?? null
  }

  return {select, bind, begin, reading, finishPair, settingsKey: () => settingsKey, summary: () => pairSummary, clearSummary}
}
