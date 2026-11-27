// Keep the chosen order when switching the first take, except when it would repeat it.
export function updateComparisonChoice(select, first, fullBlend) {
  const previous = select.value
  for (const option of select.options) {
    const unavailable = option.value === first || (option.value === "bass_swap" && !fullBlend)
    if (option.disabled !== unavailable || option.hidden !== unavailable) option.hidden = option.disabled = unavailable
  }
  const valid = [...select.options].some(option => option.value === previous && !option.disabled)
  if (!valid) select.value = first === "blend" ? "cut" : "blend"
}
