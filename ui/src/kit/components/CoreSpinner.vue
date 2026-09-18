<script setup>
// CoreSpinner — work with no measurable progress (DESIGN §37.5, Data — meters). One ring, one lit
// border side, the rest of the circle in the same tone at 22 %. The stroke scales with the size so
// a 14 px ring does not read as a hairline and a 24 px one does not read as a donut.
// `role="status"` on the root: a screen reader announces the label, or "Loading" without one.
import { computed } from 'vue'
import { METER_TONES, oneOf, toneClass } from '../use.js'

const SIZE_MAP = { sm: 14, md: 18, lg: 24 }

const props = defineProps({
  /** `'sm'` 14 | `'md'` 18 | `'lg'` 24, or a number of px. */
  size: { type: [String, Number], default: 'md' },
  /** Accent, a semantic tone or one of the vitals (§37.2). */
  tone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
  /** Optional caption after the ring, in the label voice. */
  label: { type: String, default: '' },
})

const px = computed(() => {
  const size = props.size
  if (typeof size === 'number') return Number.isFinite(size) ? size : SIZE_MAP.md
  if (SIZE_MAP[size]) return SIZE_MAP[size]
  const parsed = Number(size)
  return Number.isFinite(parsed) && String(size).trim() !== '' ? parsed : SIZE_MAP.md
})

const ringStyle = computed(() => ({
  width: px.value + 'px',
  height: px.value + 'px',
  '--core-spinner-w': Math.max(2, Math.round(px.value / 8)) + 'px',
}))
</script>

<template>
  <span class="core-spinner" :class="toneClass(tone)" role="status" :aria-label="label || 'Loading'">
    <span class="core-spinner__ring" :style="ringStyle"></span>
    <span v-if="label || $slots.default" class="core-spinner__label"><slot>{{ label }}</slot></span>
  </span>
</template>
