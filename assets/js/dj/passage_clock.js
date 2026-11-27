// The reserved exit is in source time. The DJ needs listening time at the current playback rate.
export function passageClock(choice, deck, contextState) {
  switch (choice.phase) {
    case "missed": return {text: "Ponto do ensaio já passou"}
    case "failed": return {text: "Entrada indisponível"}
    case "starting": return {text: "Preparando a entrada"}
  }
  if (contextState !== "running" || !deck.audible() || (!deck.entry && !deck.ready())) {
    return {text: "Aguardando o áudio do deck " + choice.pair.from.toUpperCase()}
  }
  const armed = choice.phase === "armed"
  const remaining = (choice.exitMs - deck.positionMs()) / deck.el.playbackRate
  if (remaining <= 0) {
    return {text: armed ? "Ponto ensaiado · aguarda confirmação" : "No ponto ensaiado"}
  }
  const seconds = Math.ceil(remaining / 1000)
  const time = Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0")
  const label = armed ? "Ponto ensaiado em" : "Na pista em"
  return {label, time, text: armed ? "Ponto em " + time + " · aguarda confirmação" : label + " " + time}
}
