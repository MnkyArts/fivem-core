<script setup>
// CoreStatRow — the detail stat of mockup 3 (DESIGN §37.5, Data — meters): heart · HEALTH RESTORE
// · +75 between two hairlines. Stacked rows share one line (the css partial drops the neighbour's
// top border), so a list of effects reads as one hairline-framed block.
// `tone` colours ONLY the value; without one the value stays white, exactly like the mockup, which
// is why the tone prop has no default — an undefined `--tone` falls back to `fg` in the partial.
import { computed } from 'vue'
import { METER_TONES, oneOf, toneClass } from '../use.js'

const props = defineProps({
  /** Registry name or raw path, 22 px, in the foreground colour. */
  icon: { type: String, default: '' },
  /** What the stat is, in the display voice (uppercase, tracked). */
  label: { type: String, default: '' },
  /** The number (slot `value` overrides it). */
  value: { type: [String, Number], default: '' },
  /** Colours the value only. Empty: the value is `fg`. */
  tone: { type: String, default: '', validator: (v) => v === '' || oneOf(METER_TONES)(v) },
  /** Which hairlines this row draws by itself. */
  hairlines: {
    type: String,
    default: 'both',
    validator: oneOf(['both', 'top', 'bottom', 'none']),
  },
})

const rootClass = computed(() => {
  const list = ['core-statrow--line-' + props.hairlines]
  if (props.tone) list.push(toneClass(props.tone))
  return list
})
</script>

<template>
  <div class="core-statrow" :class="rootClass">
    <CoreIcon v-if="icon" :name="icon" :size="22" class="core-statrow__icon" />
    <span v-if="label" class="core-statrow__label">{{ label }}</span>
    <span class="core-statrow__value"><slot name="value">{{ value }}</slot></span>
  </div>
</template>
