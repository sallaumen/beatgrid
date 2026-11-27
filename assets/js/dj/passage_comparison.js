// Compare the sound that was heard. The headphone pan and transition kind are
// intentionally outside the identity. The latter selects one of the two takes.
function soundKey(pair, plan, bpm) {
  if (!plan) return null
  const controls = ({rate, vinyl, filter, tone, level}) => [rate, vinyl, filter, tone, level]
  return JSON.stringify([pair.from, pair.to, pair.fromLoad, pair.toLoad, bpm, plan.exit, plan.inStart,
    plan.lead, plan.blend, plan.duration, controls(plan.mix.out), controls(plan.mix.into)])
}

function scoreLabel(result) {
  if (!result) return "Falta ouvir"
  return result.score == null ? "Sem nota" : `${result.score}/100`
}

export function mountPassageComparison(details, labels, selected) {
  const heard = new Map()
  let key = null, active = null
  let lastPair, lastPlan, lastBpm

  function render(restored) {
    for (const label of labels) {
      const result = heard.get(label.dataset.scoreFor)
      label.hidden = !heard.size
      label.textContent = scoreLabel(result)
    }
    const current = heard.get(selected())
    if (current) details.show(current, {restored})
    else details.clear()
  }

  function select() {
    active = null
    render(true)
  }

  function bind(pair, plan, bpm) {
    // The transport replaces the plan on edits and polls the panel while playing.
    if (pair === lastPair && plan === lastPlan && bpm === lastBpm) return
    lastPair = pair
    lastPlan = plan
    lastBpm = bpm
    const next = soundKey(pair, plan, bpm)
    if (next === key) return
    key = next
    heard.clear()
    select()
  }

  function begin(kind) {
    const take = {
      finish(result) {
        if (active !== take) return
        active = null
        heard.set(kind, result)
        render(false)
      },
      unavailable() {
        if (active !== take) return
        active = null
        const previous = heard.get(kind)
        if (previous) render(true)
        else details.show({score: null, metrics: [], summary: "Não foi possível medir esta reprodução inteira."})
      },
      cancel() {
        if (active === take) select()
      }
    }
    active = take
    details.listening()
    return take
  }

  return {select, bind, begin}
}
