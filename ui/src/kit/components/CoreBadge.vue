<script setup>
// CoreBadge — count / status pip (DESIGN §37.5, Data — display).
// `dot` wins over everything: a pip has no value, so `max` and the slot are ignored and the box
// collapses to 8 px. `max` prints "99+" rather than clipping, and only a numeric value is capped —
// a string ("NEW", "LIVE") is printed as it stands.
import { computed } from 'vue'
import { TONES, oneOf, toneClass } from '../use.js'

const props = defineProps({
  /** The count or short word inside the pip. Ignored when `dot` is set. */
  value: { type: [String, Number], default: '' },
  /** Numbers above this print as `<max>+`. */
  max: { type: Number, default: 99 },
  /** One of §37.4's six tones — sets --tone / --tone-rgb through the root class. */
  tone: { type: String, default: 'accent', validator: oneOf(TONES) },
  /** `solid` (tone fill), `soft` (14 % fill), `outline` (border only). */
  variant: { type: String, default: 'solid', validator: oneOf(['solid', 'soft', 'outline']) },
  /** Draw a bare 8 px pip instead of a count. */
  dot: { type: Boolean, default: false },
  /** Adds the breathing halo of `core-pulse` — something just happened. */
  pulse: { type: Boolean, default: false },
})

const text = computed(() => {
  const n = Number(props.value)
  if (typeof props.value === 'number' || (props.value !== '' && Number.isFinite(n))) {
    return n > props.max ? props.max + '+' : String(n)
  }
  return props.value === null || props.value === undefined ? '' : String(props.value)
})

const rootClass = computed(() => [
  'core-badge',
  'core-badge--' + props.variant,
  toneClass(props.tone),
  { 'is-dot': props.dot, 'is-pulse': props.pulse },
])
</script>

<template>
  <span :class="rootClass">
    <template v-if="!dot">
      <slot>{{ text }}</slot>
    </template>
  </span>
</template>
