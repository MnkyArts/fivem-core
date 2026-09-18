<script>
// CoreKey — a key cap (DESIGN §37.5, Actions).
// Module scope: the cap heights and the five labels that are drawn as a MOUSE GLYPH instead of a
// tile (§37.1 — "mouse buttons are line glyphs"), which is why `label` is not simply printed.
// A wide label (ESC, SPACE, SHIFT) grows the cap sideways; `min-width` only keeps it square.
const SIZE_PX = { sm: 20, md: 26, lg: 32 }
const MOUSE = new Set(['mouse', 'mouse-left', 'mouse-right', 'mouse-middle', 'mouse-scroll'])
</script>

<script setup>
import { computed, useSlots } from 'vue'
import { SIZES, clamp, oneOf } from '../use.js'

const props = defineProps({
  /** `'F'`, `'ESC'`, `'SPACE'` — or one of the five mouse names, which draw the glyph. */
  label: { type: [String, Number], default: '' },
  /** `solid` is the near-white tile of the mockups; `outline` the quieter framed cap. */
  variant: { type: String, default: 'solid', validator: oneOf(['solid', 'outline']) },
  /** Cap height: 20 | 26 | 32 px. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Held down right now — coral tile, no lip. */
  pressed: { type: Boolean, default: false },
  /** 0-1 hold-to-confirm. Bound straight to a transform, so a per-frame caller stays smooth. */
  progress: { type: Number, default: 0 },
})

const slots = useSlots()

const mouse = computed(() => {
  if (slots.default) return ''
  const name = String(props.label === null || props.label === undefined ? '' : props.label).trim().toLowerCase()
  return MOUSE.has(name) ? name : ''
})

const capPx = computed(() => SIZE_PX[props.size] || SIZE_PX.md)
const held = computed(() => clamp(Number(props.progress) || 0, 0, 1))
const holdStyle = computed(() => ({ transform: 'scaleX(' + held.value + ')' }))
</script>

<template>
  <span
    class="core-key"
    :class="[
      'core-key--' + size,
      mouse ? 'core-key--mouse' : 'core-key--' + variant,
      { 'is-pressed': pressed, 'is-holding': held > 0 },
    ]"
  >
    <CoreIcon v-if="mouse" :name="mouse" :size="capPx" />
    <slot v-else>{{ label }}</slot>
    <span v-if="held > 0" class="core-key__progress" :style="holdStyle"></span>
  </span>
</template>
