<script setup>
// CoreStatBar — the HUD vital of mockup 2 (DESIGN §37.5, Data — meters): a glyph in the vital's
// colour, a chunky flat bar in a dark well, a big condensed number. It is a read-out on the game,
// so the whole row stays click-through (§37.4) and the number keeps a floor width: 100 -> 75 must
// not resize the plate it sits on. Under `lowBelow` the GLYPH pulses — the bar itself never moves,
// a twitching meter is unreadable exactly when it matters. `iconTone` exists because mockup 2 draws
// the shield white over a blue bar: a HUD may want the colour in the bar only, row by row.
import { computed } from 'vue'
import { METER_TONES, oneOf, toPercent, toneClass } from '../use.js'

const props = defineProps({
  /** Registry name or raw path, drawn in the tone (heart, shield, bolt, food, water, …). */
  icon: { type: String, default: '' },
  value: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  /** Defaults to the health vital — this is a HUD row before it is anything else. */
  tone: { type: String, default: 'health', validator: oneOf(METER_TONES) },
  /** `'tone'`: the glyph wears the vital's colour. `'fg'`: white, the bar keeps the colour alone. */
  iconTone: { type: String, default: 'tone', validator: oneOf(['tone', 'fg']) },
  /** Bar width in px (a string passes through as a CSS length). */
  width: { type: [Number, String], default: 220 },
  /** Print the number after the bar. */
  showValue: { type: Boolean, default: true },
  /** Percent under which the glyph pulses. 0 switches the warning off. */
  lowBelow: { type: Number, default: 25 },
})

const pct = computed(() => toPercent(props.value, 0, props.max))
const isLow = computed(() => props.lowBelow > 0 && pct.value < props.lowBelow)

const rootClass = computed(() => [
  toneClass(props.tone),
  { 'is-low': isLow.value, 'core-statbar--icon-fg': props.iconTone === 'fg' },
])
const trackStyle = computed(() => ({
  width: typeof props.width === 'number' ? props.width + 'px' : String(props.width),
}))
const fillStyle = computed(() => ({ width: Math.round(pct.value * 100) / 100 + '%' }))
const text = computed(() => String(Math.round(Number(props.value) || 0)))
</script>

<template>
  <div class="core-statbar" :class="rootClass">
    <CoreIcon v-if="icon" :name="icon" :size="20" class="core-statbar__icon" />

    <div
      class="core-statbar__track"
      :style="trackStyle"
      role="progressbar"
      aria-valuemin="0"
      :aria-valuemax="max"
      :aria-valuenow="value"
      :aria-label="tone"
    >
      <div class="core-statbar__fill" :style="fillStyle"></div>
    </div>

    <span v-if="showValue" class="core-statbar__value">{{ text }}</span>
  </div>
</template>
