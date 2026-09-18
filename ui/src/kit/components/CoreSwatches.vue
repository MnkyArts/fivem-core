<script setup>
// CoreSwatches — a row of colours to pick from (DESIGN §37.5, Forms — choice).
// Real <button aria-pressed> elements, not divs: the whole group is one tab stop and ← / → rove
// between the swatches, picking as they go, because a colour picker is judged by what the ped or
// the car looks like right now. A plain string item is both the value and the paint; an object
// may split them (`{ value: 'carmine', color: '#8c1c13', label: 'Carmine' }`).
import { computed, ref } from 'vue'
import { nextEnabledIndex, normalizeItems, oneOf, SIZES } from '../use.js'

const props = defineProps({
  /** Strings (`'#f6503f'`) or `{ value, color, label?, disabled? }`. */
  items: { type: Array, default: () => [] },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  shape: { type: String, default: 'square', validator: oneOf(['square', 'circle']) },
  /** Lay the swatches out in a grid of this many columns instead of a wrapping row. */
  columns: { type: Number, default: 0 },
  disabled: { type: Boolean, default: false },
})

const model = defineModel({ type: null, default: undefined })

const buttons = ref([])
const list = computed(() => normalizeItems(props.items).map((item) => Object.assign({}, item, {
  color: item.color || item.value,
  disabled: Boolean(item.disabled) || props.disabled,
})))

const selected = computed(() => list.value.findIndex((item) => item.value === model.value))

function setRef(el, i) {
  if (el) buttons.value[i] = el
}

function pick(item) {
  if (item.disabled) return
  model.value = item.value
}

/** Rove and pick in one go; Home / End jump to the ends. */
function onKeydown(event, index) {
  const key = event.key
  let next = -1
  if (key === 'ArrowRight' || key === 'ArrowDown') next = nextEnabledIndex(list.value, index, 1)
  else if (key === 'ArrowLeft' || key === 'ArrowUp') next = nextEnabledIndex(list.value, index, -1)
  else if (key === 'Home') next = nextEnabledIndex(list.value, -1, 1)
  else if (key === 'End') next = nextEnabledIndex(list.value, list.value.length, -1)
  if (next === -1 || next === index) return
  event.preventDefault()
  pick(list.value[next])
  const el = buttons.value[next]
  if (el && typeof el.focus === 'function') el.focus()
}
</script>

<template>
  <div
    class="core-swatches"
    :class="[
      'core-swatches--' + size,
      shape === 'circle' ? 'core-swatches--circle' : null,
      columns > 0 ? 'core-swatches--grid' : null,
      { 'is-disabled': disabled },
    ]"
    :style="columns > 0 ? { gridTemplateColumns: 'repeat(' + columns + ', max-content)' } : null"
    role="group"
  >
    <button
      v-for="(item, i) in list"
      :key="String(item.value)"
      :ref="(el) => setRef(el, i)"
      type="button"
      class="core-swatch"
      :class="{ 'is-selected': item.value === model }"
      :style="{ backgroundColor: item.color }"
      :disabled="item.disabled"
      :aria-pressed="item.value === model"
      :aria-label="item.label"
      :title="item.label"
      :tabindex="selected === -1 ? (i === 0 ? 0 : -1) : (i === selected ? 0 : -1)"
      @click="pick(item)"
      @keydown="onKeydown($event, i)"
    ></button>
  </div>
</template>
