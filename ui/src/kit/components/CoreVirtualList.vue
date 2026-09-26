<script setup>
// CoreVirtualList — a fixed-row-height virtualised list (DESIGN §53, §37.5 Data — display).
// The ROOT is the scroll box (a caller's `height` / `max-height` lands on it, like CoreTable). A
// spacer as tall as every row keeps the scrollbar honest; only the rows inside the viewport plus
// `overscan` on either side exist in the DOM, moved into place by ONE `transform` on the window.
// Without a height constraint the box grows to the spacer, the viewport is the whole list and
// every row renders — which is why CoreTree can always go through this component.
// The viewport height comes from a ResizeObserver, the offset from a passive scroll listener; no
// per-frame work, nothing measured per row. `scrollToIndex()` is the only way to move it by hand.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** The rows. Anything array-like; each one reaches the default slot as `item`. */
  items: { type: Array, default: () => [] },
  /** Every row's height in CSS px — fixed, that is the whole trick. */
  itemHeight: { type: Number, default: 36, validator: (v) => Number.isFinite(v) && v > 0 },
  /** Which field identifies a row (the `:key`); the index when a row has none. */
  keyField: { type: String, default: 'id' },
  /** Rows rendered beyond each edge of the viewport, so a fast wheel never shows a gap. */
  overscan: { type: Number, default: 6, validator: (v) => Number.isFinite(v) && v >= 0 },
  /** Distance from the bottom, in rows, at which `reach-end` fires (a cursor page loader). */
  endThreshold: { type: Number, default: 4 },
  /** ARIA role of the root; the rows become `listitem`s only while it is `list`. */
  role: { type: String, default: 'list', validator: oneOf(['list', 'listbox', 'presentation', 'none']) },
  /** The line shown when `items` is empty; the `empty` slot replaces it. */
  empty: { type: String, default: '' },
})

const emit = defineEmits(['range', 'reach-end'])

const rootRef = ref(null)
const scrollTop = ref(0)
const viewport = ref(0)
let observer = null
let endFiredAt = -1

const count = computed(() => (Array.isArray(props.items) ? props.items.length : 0))
const totalHeight = computed(() => count.value * props.itemHeight)

// Two NUMBER computeds, not one object: Vue only re-runs a dependant when a computed's value
// changed, so a scroll inside the same row window re-renders nothing.
const first = computed(() => Math.floor(scrollTop.value / props.itemHeight))
const start = computed(() => Math.max(0, first.value - props.overscan))
const end = computed(() => {
  const last = Math.ceil((scrollTop.value + viewport.value) / props.itemHeight)
  return Math.max(start.value, Math.min(count.value, Math.max(last, first.value + 1) + props.overscan))
})

const rows = computed(() => {
  const out = []
  for (let i = start.value; i < end.value; i += 1) {
    const item = props.items[i]
    const key = item !== null && typeof item === 'object' && item[props.keyField] !== undefined
      ? item[props.keyField]
      : i
    out.push({ item, index: i, key })
  }
  return out
})

const windowStyle = computed(() => ({ transform: 'translateY(' + start.value * props.itemHeight + 'px)' }))
const spacerStyle = computed(() => ({ height: totalHeight.value + 'px' }))
const rowStyle = computed(() => ({ height: props.itemHeight + 'px' }))

function measure () {
  const el = rootRef.value
  if (!el) return
  viewport.value = el.clientHeight
  scrollTop.value = el.scrollTop
}

function onScroll () {
  const el = rootRef.value
  if (el) scrollTop.value = el.scrollTop
}

watch([start, end], ([s, e]) => {
  emit('range', { start: s, end: e })
  const nearEnd = count.value > 0 && e >= count.value - props.endThreshold
  if (nearEnd && endFiredAt !== count.value) {
    endFiredAt = count.value
    emit('reach-end')
  }
})

// Shrinking the list under the current offset must not leave the window past the end.
watch(count, () => { requestAnimationFrame(measure) })

/**
 * Scrolls so the row at `index` is visible.
 * @param {number} index
 * @param {'auto'|'start'|'center'|'end'} [align] `auto` moves only when the row is not fully visible
 */
function scrollToIndex (index, align = 'auto') {
  const el = rootRef.value
  if (!el || count.value === 0) return
  const i = Math.min(Math.max(0, Math.floor(Number(index) || 0)), count.value - 1)
  const h = props.itemHeight
  const top = i * h
  const view = el.clientHeight
  let next = el.scrollTop
  if (align === 'start') next = top
  else if (align === 'end') next = top + h - view
  else if (align === 'center') next = top + h / 2 - view / 2
  else if (top < el.scrollTop) next = top
  else if (top + h > el.scrollTop + view) next = top + h - view
  el.scrollTop = Math.max(0, next)
  scrollTop.value = el.scrollTop
}

onMounted(() => {
  measure()
  if (typeof ResizeObserver === 'function' && rootRef.value) {
    observer = new ResizeObserver(measure)
    observer.observe(rootRef.value)
  }
})
onBeforeUnmount(() => { if (observer) observer.disconnect() })

defineExpose({ scrollToIndex, measure })
</script>

<template>
  <div
    ref="rootRef"
    class="core-virtuallist core-scroll"
    :class="{ 'is-empty': count === 0 }"
    :role="role"
    @scroll.passive="onScroll"
  >
    <div class="core-virtuallist__spacer" :style="spacerStyle">
      <div class="core-virtuallist__window" :style="windowStyle">
        <div
          v-for="row in rows"
          :key="row.key"
          class="core-virtuallist__row"
          :style="rowStyle"
          :role="role === 'list' ? 'listitem' : undefined"
          :data-index="row.index"
        >
          <slot :item="row.item" :index="row.index" />
        </div>
      </div>
    </div>
    <div v-if="count === 0 && (empty || $slots.empty)" class="core-virtuallist__empty">
      <slot name="empty"><p>{{ empty }}</p></slot>
    </div>
  </div>
</template>
