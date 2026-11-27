// Compare the sound that was heard. The headphone pan and transition kind are
// intentionally outside the identity. The latter selects one of the two takes.
export function rehearsalKey(pair, plan, bpm) {
  if (!plan) return null
  const controls = ({rate, vinyl, filter, tone, level}) => [rate, vinyl, filter, tone, level]
  return JSON.stringify([pair.from, pair.to, pair.fromLoad, pair.toLoad, bpm, plan.exit, plan.inStart,
    plan.lead, plan.blend, plan.duration, controls(plan.mix.out), controls(plan.mix.into), plan.blendCurve ?? null])
}

function scoreLabel(result, unavailable) {
  if (!result) return unavailable ? "Sem medição" : "Falta ouvir"
  return result.score == null ? "Sem nota" : `${result.score}/100`
}

export function mountPassageComparison(details, labels, selected, name) {
  const heard = new Map()
  const unavailable = new Set()
  let key = null, active = null, pairSummary = ""
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

  function select() {
    active = null
    pairSummary = ""
    render(true)
  }

  function bind(pair, plan, bpm) {
    // The transport replaces the plan on edits and polls the panel while playing.
    if (pair === lastPair && plan === lastPlan && bpm === lastBpm) return
    lastPair = pair
    lastPlan = plan
    lastBpm = bpm
    const next = rehearsalKey(pair, plan, bpm)
    if (next === key) return
    key = next
    heard.clear()
    unavailable.clear()
    select()
  }

  function begin(kind) {
    pairSummary = ""
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
  }

  function reading() {
    const kind = selected()
    return unavailable.has(kind) ? null : heard.get(kind) ?? null
  }

  return {select, bind, begin, reading, finishPair, summary: () => pairSummary, clearSummary() { pairSummary = "" }}
}
