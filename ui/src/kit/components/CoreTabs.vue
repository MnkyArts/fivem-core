<script setup>
// CoreTabs — top navigation (DESIGN §37.5, Navigation).
// The active tab IS the v-model value; with no `v-model` bound `defineModel` keeps the value
// locally, so a read-only header still highlights its first enabled tab. Roving tabindex: exactly
// one tab stop for the whole row, and ←/→/Home/End move selection AND focus together (a tab panel
// that follows the arrow keys is the pattern every game menu uses).
// The underline is a per-tab `::after` that only fades (css/navigation.css) — no slider element,
// so switching tabs never measures the DOM.
import { computed, useTemplateRef } from 'vue'
import { SIZES, oneOf, normalizeItems, nextEnabledIndex } from '../use.js'

const ICON_PX = { sm: 15, md: 18, lg: 21 }

const props = defineProps({
  /** `[{ value, label, icon?, badge?, disabled? }]` — strings are allowed (normalizeItems). */
  items: { type: Array, default: () => [] },
  /** `'sm'` 14 px | `'md'` 17 px | `'lg'` 20 px label. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Hairline between the tabs (the map header of the mockups). */
  separators: { type: Boolean, default: false },
  /** Spread the tabs over the full width instead of hugging their labels. */
  stretch: { type: Boolean, default: false },
  /** The hairline under the whole row that the active underline sits on. */
  line: { type: Boolean, default: true },
  /** Key cap before the row: clicking it selects the previous tab (`'Q'`, `'mouse-left'`). */
  prevKey: { type: String, default: '' },
  /** Key cap after the row: clicking it selects the next tab. */
  nextKey: { type: String, default: '' },
})

const emit = defineEmits(['change'])
const model = defineModel()
const listEl = useTemplateRef('listEl')

const list = computed(() => normalizeItems(props.items))

// No model value yet (uncontrolled, or a value that is not in `items`) -> the first enabled tab.
const fallback = computed(() => {
  const i = list.value.findIndex((item) => !item.disabled)
  return i === -1 ? undefined : list.value[i].value
})
const activeIndex = computed(() => {
  const i = list.value.findIndex((item) => item.value === model.value)
  return i === -1 ? list.value.findIndex((item) => item.value === fallback.value) : i
})

const rootClass = computed(() => [
  'core-tabs--' + props.size,
  {
    'core-tabs--line': props.line,
    'core-tabs--separators': props.separators,
    'core-tabs--stretch': props.stretch,
  },
])
const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)

function select (index) {
  const item = list.value[index]
  if (!item || item.disabled || index === activeIndex.value) return
  model.value = item.value
  emit('change', item.value, item)
}

function focusAt (index) {
  const el = listEl.value && listEl.value.children ? listEl.value.children[index] : null
  if (el && typeof el.focus === 'function') el.focus()
}

/** `dir` +1 / -1 from the active tab; `edge` jumps to the first/last enabled one (Home/End). */
function move (dir, { edge = false, focus = false } = {}) {
  const from = edge ? (dir < 0 ? list.value.length : -1) : activeIndex.value
  const next = nextEnabledIndex(list.value, from, dir, !edge)
  if (next === from || next < 0) return
  select(next)
  if (focus) focusAt(next)
}

function onKeydown (event) {
  const key = event.key
  if (key === 'ArrowRight' || key === 'ArrowDown') move(1, { focus: true })
  else if (key === 'ArrowLeft' || key === 'ArrowUp') move(-1, { focus: true })
  else if (key === 'Home') move(1, { edge: true, focus: true })
  else if (key === 'End') move(-1, { edge: true, focus: true })
  else return
  event.preventDefault()
}
</script>

<template>
  <div class="core-tabs" :class="rootClass">
    <button
      v-if="prevKey"
      type="button"
      class="core-tabs__key"
      :aria-label="'Previous tab (' + prevKey + ')'"
      @click="move(-1)"
    >
      <CoreKey :label="prevKey" variant="outline" size="sm" />
    </button>

    <div ref="listEl" class="core-tabs__list" role="tablist" @keydown="onKeydown">
      <button
        v-for="(item, i) in list"
        :key="i"
        type="button"
        role="tab"
        class="core-tab"
        :class="{ 'is-active': i === activeIndex, 'is-disabled': !!item.disabled }"
        :disabled="!!item.disabled"
        :tabindex="i === activeIndex ? 0 : -1"
        :aria-selected="i === activeIndex ? 'true' : 'false'"
        @click="select(i)"
      >
        <slot name="tab" :item="item" :active="i === activeIndex">
          <CoreIcon v-if="item.icon" :name="item.icon" :size="iconPx" />
          <span class="core-tab__label">{{ item.label }}</span>
          <span v-if="item.badge !== undefined && item.badge !== null && item.badge !== ''" class="core-tab__badge">
            {{ item.badge }}
          </span>
        </slot>
      </button>
    </div>

    <button
      v-if="nextKey"
      type="button"
      class="core-tabs__key"
      :aria-label="'Next tab (' + nextKey + ')'"
      @click="move(1)"
    >
      <CoreKey :label="nextKey" variant="outline" size="sm" />
    </button>
  </div>
</template>
