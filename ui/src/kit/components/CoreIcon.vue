<script>
// CoreIcon — a registry glyph (DESIGN §37.5, Foundation).
// Module scope on purpose: the size table is shared, and `warned` keeps an unknown icon name from
// filling the console — one line per name for the whole session, not one per render.
const SIZE_MAP = { xs: 14, sm: 16, md: 20, lg: 24, xl: 32 }
const warned = new Set()
</script>

<script setup>
import { computed } from 'vue'
import { iconPath } from '../icons.js'

const props = defineProps({
  /** Registry name (`'map-marker'`) or raw 24 x 24 path data. */
  name: { type: String, default: '' },
  /** Explicit raw path data; wins over `name`. */
  path: { type: String, default: '' },
  /** `'xs'` 14 | `'sm'` 16 | `'md'` 20 | `'lg'` 24 | `'xl'` 32, or a number of px. */
  size: { type: [String, Number], default: 'md' },
  /** Spins the glyph (loading states) — the animation lives in css/base.css. */
  spin: { type: Boolean, default: false },
  /** Accessible name. Without it the glyph is decoration and is hidden from the a11y tree. */
  title: { type: String, default: '' },
})

const px = computed(() => {
  const size = props.size
  if (typeof size === 'number') return Number.isFinite(size) ? size : SIZE_MAP.md
  const mapped = SIZE_MAP[size]
  if (mapped) return mapped
  const parsed = Number(size)
  return Number.isFinite(parsed) && String(size).trim() !== '' ? parsed : SIZE_MAP.md
})

const d = computed(() => {
  if (props.path) return props.path
  if (!props.name) return ''
  const resolved = iconPath(props.name)
  if (!resolved && !warned.has(props.name)) {
    warned.add(props.name)
    console.warn('[core:ui] unknown icon "' + props.name + '" — register it with CoreUI.kit.registerIcons()')
  }
  return resolved
})
</script>

<template>
  <svg
    class="core-icon"
    :class="{ 'is-spin': spin }"
    viewBox="0 0 24 24"
    fill="currentColor"
    :width="px"
    :height="px"
    :role="title ? 'img' : null"
    :aria-hidden="title ? null : 'true'"
    focusable="false"
  >
    <title v-if="title">{{ title }}</title>
    <path v-if="d" :d="d" />
  </svg>
</template>
