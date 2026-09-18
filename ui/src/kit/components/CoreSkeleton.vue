<script setup>
// CoreSkeleton — the placeholder a page shows while its data is still in flight (DESIGN §37.5,
// Data — meters): white 6 % with a highlight sweeping across it. A multi-line block ends short,
// the way a real paragraph does, so the shimmer does not read as a table.
// It is decoration for the a11y tree (`aria-hidden`): the loading state itself is announced by
// whatever asked for the data, usually a CoreSpinner with `role="status"`.
import { computed } from 'vue'

const props = defineProps({
  /** Block width — a number is px, a string passes through (`'60%'`, `'12ch'`). */
  width: { type: [Number, String], default: '100%' },
  /** Height of ONE line, in px (or a CSS length). */
  height: { type: [Number, String], default: 14 },
  /** How many lines to stack. */
  lines: { type: Number, default: 1 },
  /** Corner radius — a number is px. Defaults to the 3 px chip radius. */
  radius: { type: [Number, String], default: '' },
})

const length = (v, fallback) => {
  if (v === '' || v === null || v === undefined) return fallback
  return typeof v === 'number' ? v + 'px' : String(v)
}

const count = computed(() => {
  const n = Math.floor(Number(props.lines))
  return Number.isFinite(n) && n > 1 ? n : 1
})

// A single line puts its height on the ROOT and fills it, so `height="100%"` works inside a box
// that has one (an inventory slot); a stack keeps the height per line and grows with them.
const rootStyle = computed(() => {
  const style = { width: length(props.width, '100%') }
  if (count.value === 1) style.height = length(props.height, '14px')
  return style
})
const lineStyle = computed(() => ({
  height: count.value === 1 ? '100%' : length(props.height, '14px'),
  borderRadius: length(props.radius, 'var(--radius-ui-xs)'),
}))
</script>

<template>
  <div
    class="core-skeleton"
    :class="{ 'core-skeleton--lines': count > 1 }"
    :style="rootStyle"
    aria-hidden="true"
  >
    <div v-for="n in count" :key="n" class="core-skeleton__line" :style="lineStyle"></div>
  </div>
</template>
