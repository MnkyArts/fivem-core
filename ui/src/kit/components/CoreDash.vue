<script setup>
// CoreDash — the short accent bar of §37.1 (DESIGN §37.5, Surfaces): under a heading, after the
// footer line of the main menu, below a tagline. Pure decoration, so it is aria-hidden and takes
// no pointer events; the accent tone wears the brand gradient instead of a flat fill.
import { computed } from 'vue'
import { oneOf, toneClass, METER_TONES } from '../use.js'

const props = defineProps({
  /** Length in px (a string passes through, so `"100%"` works inside a flex row). */
  width: { type: [Number, String], default: 28 },
  /** Any kit tone — the dash is the one place a screen repeats its accent colour. */
  tone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
})

const style = computed(() => ({
  width: typeof props.width === 'number' ? props.width + 'px' : String(props.width),
}))

const rootClass = computed(() => ['core-dash', toneClass(props.tone)])
</script>

<template>
  <span :class="rootClass" :style="style" aria-hidden="true"></span>
</template>
