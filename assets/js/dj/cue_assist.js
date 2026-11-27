import {startCueAnalysis} from "./cue_analysis.js"

const cueTime = new Intl.NumberFormat("pt-BR", {minimumFractionDigits: 3, maximumFractionDigits: 3})
const cueSeconds = value => cueTime.format(value) + " s"

export function mountCueAssist(section, {audition, refresh, analyze = startCueAnalysis}) {
  const check = section.querySelector("[data-cue-check]")
  const trial = section.querySelector("[data-cue-try]")
  const restore = section.querySelector("[data-cue-restore]")
  const note = section.querySelector("[data-cue-note]")
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
    else if (!context.outBpm || !context.intoBpm) message = "O encaixe precisa do BPM das duas faixas."
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
  restore.onclick = () => {
    refresh?.()
    if (context?.plan.originalEntry == null) return
    audition(context.plan.originalEntry, null)
    if (!trial.hidden) trial.focus()
    else check.focus()
  }
  reset()
  return {update, reset}
}
