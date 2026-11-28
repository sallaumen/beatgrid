import {startCueAnalysis} from "./cue_analysis.js"

const cueTime = new Intl.NumberFormat("pt-BR", {minimumFractionDigits: 3, maximumFractionDigits: 3})
const cueSeconds = value => cueTime.format(value) + " s"

// Positive steps advance into the record, bringing its next attack forward at the heard tempo.
function steppedEntry(plan, kind, direction) {
  if (!plan) return null
  const rate = plan.mix.into.rate
  const original = plan.originalEntry ?? plan.inStart
  const step = plan.inStart + direction * .025 * rate
  let entry = step
  if (Math.abs(entry - original) < 1e-9) entry = original
  else if (Math.abs(entry) < 1e-9) entry = 0
  const remaining = plan.incoming.duration - entry
  if (entry < 0 || remaining < 1 / plan.incoming.sampleRate) return null
  if (kind === "bass_swap" && direction > 0 && (!plan.fullBlend || remaining / rate + 1e-9 < plan.blend)) return null
  return entry
}

export function mountCueAssist(section, {manual, audition, refresh, analyze = startCueAnalysis}) {
  const check = section.querySelector("[data-cue-check]")
  const trial = section.querySelector("[data-cue-try]")
  const restore = section.querySelector("[data-cue-restore]")
  const note = section.querySelector("[data-cue-note]")
  const earlier = manual.querySelector("[data-cue-step=earlier]")
  const later = manual.querySelector("[data-cue-step=later]")
  const offset = manual.querySelector("[data-cue-offset]")
  let context, inputs, key, candidate, cancel, revision = 0, state = "idle"

  function paint() {
    const plan = context?.plan
    const applied = plan?.originalEntry != null
    section.hidden = !plan
    check.hidden = applied || !!candidate
    check.disabled = !plan || !context.outBpm || !context.intoBpm
    check.ariaDisabled = String(state === "working")
    trial.hidden = !candidate || applied
    trial.disabled = !context?.phones
    restore.hidden = !applied
    for (const [button, direction] of [[earlier, 1], [later, -1]]) {
      button.disabled = !plan || !context.phones
      // At the end of the available audio, keep the operator on the same button.
      button.ariaDisabled = String(button.disabled || steppedEntry(plan, context?.kind, direction) === null)
    }
    const delta = applied ? 1000 * (plan.inStart - plan.originalEntry) / plan.mix.into.rate : 0
    let position = plan ? "No CUE original" : ""
    if (delta !== 0) {
      const magnitude = Math.round(Math.abs(delta))
      position = (magnitude ? magnitude + " ms " : "Menos de 1 ms ") + (delta > 0 ? "mais cedo" : "mais tarde")
    }
    if (offset.textContent !== position) offset.textContent = position
    if (!plan) return
    let message = "CUE no arquivo de entrada em " + cueSeconds(plan.inStart) + "."
    if (applied) message = "CUE do ensaio em " + cueSeconds(plan.inStart) + " · original em " + cueSeconds(plan.originalEntry) + "."
    else if (state === "failed") message = "Não foi possível comparar as batidas. Tente novamente."
    else if (state === "working") message = "Comparando as batidas dos dois decks…"
    else if (candidate) {
      const ms = Math.round(Math.abs(candidate.wallDelta) * 1000)
      message = "Ataque " + ms + " ms " + (candidate.wallDelta > 0 ? "mais cedo" : "mais tarde") +
        " no fone · CUE de " + cueSeconds(plan.inStart) + " para " + cueSeconds(candidate.entry) + " no arquivo."
    } else if (state === "measured") message = "Trecho sem ajuste confiável. CUE em " + cueSeconds(plan.inStart) + "."
    else if (!context.outBpm || !context.intoBpm) message = "A verificação automática precisa do BPM das duas faixas."
    if (note.textContent !== message) note.textContent = message
  }

  function reset() {
    revision++
    cancel?.()
    cancel = candidate = key = context = inputs = null
    state = "idle"
    paint()
  }

  function update(next) {
    const plan = next.plan
    if (!plan) { if (context) reset(); return }
    const original = plan.originalEntry ?? plan.inStart
    const signature = [next.pair, next.kind, next.outBpm, next.intoBpm, next.deckCue,
      plan.outgoing, plan.incoming, plan.exit, original, plan.mix.out.rate, plan.mix.into.rate]
    if (!key || signature.some((value, i) => value !== key[i])) {
      reset()
      key = signature
      inputs = {
        out: {buffer: plan.outgoing, cue: plan.exit, bpm: next.outBpm, rate: plan.mix.out.rate},
        into: {buffer: plan.incoming, cue: original, bpm: next.intoBpm, rate: plan.mix.into.rate}
      }
    } else if (context.phones === next.phones && context.plan.inStart === plan.inStart && context.plan.originalEntry === plan.originalEntry) {
      context = next
      return
    }
    context = next
    paint()
  }

  check.onclick = () => {
    refresh?.()
    if (check.disabled || check.hidden || state === "working") return
    const ticket = ++revision
    state = "working"
    paint()
    cancel = analyze(inputs, (result, failed) => {
      if (ticket !== revision) return
      const focused = section.ownerDocument?.activeElement === check
      cancel = null
      state = failed ? "failed" : "measured"
      candidate = result
      paint()
      if (candidate && focused) (trial.disabled ? note : trial).focus()
    })
  }
  trial.onclick = () => {
    refresh?.()
    if (!candidate || trial.disabled || trial.hidden) return
    audition(candidate.entry, context.plan.inStart)
    if (!restore.hidden) restore.focus()
  }
  for (const [button, direction] of [[earlier, 1], [later, -1]]) {
    button.onclick = () => {
      refresh?.()
      if (!context?.phones) return
      const {plan, kind} = context
      const entry = steppedEntry(plan, kind, direction)
      if (entry === null) return
      const original = plan.originalEntry ?? plan.inStart
      audition(entry, entry === original ? null : original)
    }
  }
  restore.onclick = () => {
    refresh?.()
    if (context?.plan.originalEntry == null) return
    audition(context.plan.originalEntry, null)
    if (!trial.hidden) trial.focus()
    else (check.disabled ? note : check).focus()
  }
  reset()
  return {update, reset}
}
