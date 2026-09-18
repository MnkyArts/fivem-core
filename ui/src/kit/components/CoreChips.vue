<script setup>
// CoreChips — filter chips / segmented control (DESIGN §37.5, Navigation): the quest filter row of
// the mockups, the selected chip solid coral and the rest outlined wells.
//
// `multiple` swaps the model for an ARRAY of values; `allowEmpty` decides whether the last active
// chip can be switched off (a filter row that can select nothing usually shows nothing, so the
// default is no). Roving tabindex: one tab stop, ←/→ move the FOCUS only — a chip is a toggle, so
// arrowing onto it must not silently change the filter; Space/Enter (the native button click) does.
// `stretch` (equal-width cells) and `minWidth` (a floor under every chip) are what turn the same
// component into the segmented filter bar of the map mockup; `minWidth` rides on one custom
// property on the group instead of an inline style per chip.
import { computed, ref, useTemplateRef } from 'vue'
import { SIZES, oneOf, normalizeItems, nextEnabledIndex } from '../use.js'

const ICON_PX = { sm: 13, md: 15, lg: 17 }

const props = defineProps({
  /** `[{ value, label, icon?, count?, disabled? }]` — strings are allowed (normalizeItems). */
  items: { type: Array, default: () => [] },
  /** The model becomes an array of values and every chip toggles on its own. */
  multiple: { type: Boolean, default: false },
  /** Allow switching the last active chip off (single: back to `null`). */
  allowEmpty: { type: Boolean, default: false },
  /** Chip height 28 / 36 / 44 px. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Wrap onto more lines instead of one row. */
  wrap: { type: Boolean, default: false },
  /** Equal-width cells filling the row — the segmented filter bar of the map mockup. */
  stretch: { type: Boolean, default: false },
  /** A floor under every chip, in px, so short labels keep their neighbours' width. */
  minWidth: { type: Number, default: 0, validator: (v) => Number.isFinite(v) && v >= 0 },
})

const model = defineModel()
const rootEl = useTemplateRef('rootEl')
const focusIndex = ref(-1)

const list = computed(() => normalizeItems(props.items))

const selected = computed(() => {
  if (!props.multiple) return model.value
  return Array.isArray(model.value) ? model.value : []
})

function isActive (item) {
  if (props.multiple) return selected.value.indexOf(item.value) !== -1
  return selected.value !== undefined && selected.value !== null && selected.value === item.value
}

// The one tab stop: whatever the arrows last landed on, else the first active chip, else the first
// enabled one — so Tab never drops the keyboard into a disabled chip.
const tabStop = computed(() => {
  if (focusIndex.value >= 0 && focusIndex.value < list.value.length) return focusIndex.value
  const active = list.value.findIndex((item) => isActive(item) && !item.disabled)
  if (active !== -1) return active
  return Math.max(0, list.value.findIndex((item) => !item.disabled))
})

const rootClass = computed(() => [
  'core-chips--' + props.size,
  { 'core-chips--wrap': props.wrap, 'core-chips--stretch': props.stretch },
])
const rootStyle = computed(() => (props.minWidth > 0 ? { '--core-chip-min': props.minWidth + 'px' } : null))
const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)

function toggle (index) {
  const item = list.value[index]
  if (!item || item.disabled) return
  focusIndex.value = index
  if (props.multiple) {
    const next = selected.value.slice()
    const at = next.indexOf(item.value)
    if (at === -1) next.push(item.value)
    else if (props.allowEmpty || next.length > 1) next.splice(at, 1)
    else return
    model.value = next
    return
  }
  if (isActive(item)) {
    if (props.allowEmpty) model.value = null
    return
  }
  model.value = item.value
}

function focusAt (index) {
  const el = rootEl.value && rootEl.value.children ? rootEl.value.children[index] : null
  if (el && typeof el.focus === 'function') el.focus()
}

function move (dir, edge = false) {
  const from = edge ? (dir < 0 ? list.value.length : -1) : tabStop.value
  const next = nextEnabledIndex(list.value, from, dir, !edge)
  if (next === from || next < 0) return
  focusIndex.value = next
  focusAt(next)
}

function onKeydown (event) {
  const key = event.key
  if (key === 'ArrowRight' || key === 'ArrowDown') move(1)
  else if (key === 'ArrowLeft' || key === 'ArrowUp') move(-1)
  else if (key === 'Home') move(1, true)
  else if (key === 'End') move(-1, true)
  else return
  event.preventDefault()
}

const hasCount = (item) => item.count !== undefined && item.count !== null && item.count !== ''
</script>

<template>
  <div ref="rootEl" class="core-chips" :class="rootClass" :style="rootStyle" role="group" @keydown="onKeydown">
    <button
      v-for="(item, i) in list"
      :key="i"
      type="button"
      class="core-chip"
      :class="{ 'is-active': isActive(item), 'is-disabled': !!item.disabled }"
      :disabled="!!item.disabled"
      :tabindex="i === tabStop ? 0 : -1"
      :aria-pressed="isActive(item) ? 'true' : 'false'"
      @click="toggle(i)"
    >
      <slot name="chip" :item="item" :active="isActive(item)">
        <CoreIcon v-if="item.icon" :name="item.icon" :size="iconPx" />
        <span class="core-chip__label">{{ item.label }}</span>
        <span v-if="hasCount(item)" class="core-chip__count">{{ item.count }}</span>
      </slot>
    </button>
  </div>
</template>
