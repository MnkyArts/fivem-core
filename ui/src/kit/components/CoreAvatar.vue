<script>
// Module scope: `defineProps()` is hoisted out of setup(), so the tables its validators read have
// to live here (the same split CoreIcon.vue uses).
const SIZE_MAP = { sm: 28, md: 40, lg: 56, xl: 76 }
const STATUSES = ['online', 'away', 'busy', 'offline']
</script>

<script setup>
// CoreAvatar — portrait, initials fallback, presence dot (DESIGN §37.5, Data — display).
// Everything that depends on the pixel size (the box, the initials, the dot) is an inline style:
// `size` accepts a number, so a class per step would only cover the four named ones. A broken image
// url falls back to the initials at runtime — a player's avatar comes from outside the shell.
import { computed, ref, watch } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** Image url. Empty (or a load error) shows the initials instead. */
  src: { type: String, default: '' },
  /** Used for the initials and for the alt text: up to two words are taken. */
  name: { type: String, default: '' },
  /** `'sm'` 28 | `'md'` 40 | `'lg'` 56 | `'xl'` 76, or a number of px. */
  size: { type: [String, Number], default: 'md' },
  /** `square` (4 px radius) or `circle`. */
  shape: { type: String, default: 'square', validator: oneOf(['square', 'circle']) },
  /** Presence dot in the bottom-right corner; empty draws none. */
  status: { type: String, default: '', validator: (v) => v === '' || STATUSES.indexOf(v) !== -1 },
  /** 2 px accent-hi outline with a 2 px ink gap — "this is you" / "this row is selected". */
  ring: { type: Boolean, default: false },
})

const failed = ref(false)
watch(() => props.src, () => { failed.value = false })

const px = computed(() => {
  if (typeof props.size === 'number') return Number.isFinite(props.size) ? props.size : SIZE_MAP.md
  const mapped = SIZE_MAP[props.size]
  if (mapped) return mapped
  const parsed = Number(props.size)
  return Number.isFinite(parsed) && String(props.size).trim() !== '' ? parsed : SIZE_MAP.md
})

const initials = computed(() => String(props.name || '')
  .trim()
  .split(/\s+/)
  .filter(Boolean)
  .slice(0, 2)
  .map((word) => word.charAt(0))
  .join(''))

const showImage = computed(() => Boolean(props.src) && !failed.value)

const rootStyle = computed(() => ({
  width: px.value + 'px',
  height: px.value + 'px',
  fontSize: Math.max(10, Math.round(px.value * 0.38)) + 'px',
}))

const dotStyle = computed(() => {
  const d = Math.min(16, Math.max(8, Math.round(px.value * 0.26)))
  return { width: d + 'px', height: d + 'px' }
})

const rootClass = computed(() => [
  'core-avatar',
  'core-avatar--' + props.shape,
  { 'is-ring': props.ring },
])
</script>

<template>
  <span :class="rootClass" :style="rootStyle">
    <img
      v-if="showImage"
      class="core-avatar__img"
      :src="src"
      :alt="name || ''"
      @error="failed = true"
    >
    <span v-else class="core-avatar__initials" aria-hidden="true">{{ initials }}</span>
    <span
      v-if="status"
      class="core-avatar__status"
      :class="'is-' + status"
      :style="dotStyle"
      :title="status"
    ></span>
  </span>
</template>
