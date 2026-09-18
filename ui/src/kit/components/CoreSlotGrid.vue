<script setup>
// CoreSlotGrid — the inventory grid of mockup 3 (DESIGN §37.5, Game).
// A CSS grid of CoreSlots with ONE tab stop: the arrow keys rove in 2D (roving tabindex), and
// `slots` pads the list with empty cells so a half-full bag still draws a full rectangle.
// The `slot` scoped slot renders INSIDE each cell (CoreSlot's own default slot), which keeps the
// grid in charge of focus while a page can still overlay its own markup per item.
import { computed, ref } from 'vue'

const props = defineProps({
  /** `[{ id, image?, icon?, count?, rarity?, durability?, badge?, disabled?, … }]` — CoreSlot props. */
  items: { type: Array, default: () => [] },
  columns: { type: Number, default: 4 },
  gap: { type: Number, default: 12 },
  /** Pad with empty cells up to this many slots (the bag's capacity). */
  slots: { type: Number, default: 0 },
  ratio: { type: String, default: '1 / 1' },
})

/** `v-model:selected` — the id of the selected item. */
const selected = defineModel('selected', { type: [String, Number], default: null })
const emit = defineEmits(['select'])

// `id` is the identity of a cell, never a CoreSlot prop — it is split off so it cannot land on
// the <button> as a DOM id when the rest of the item is spread onto the slot.
const cells = computed(() => {
  const list = Array.isArray(props.items) ? props.items : []
  const out = []
  for (let i = 0; i < list.length; i += 1) {
    const item = list[i] || {}
    const rest = Object.assign({}, item)
    delete rest.id
    out.push({
      id: item.id === undefined || item.id === null ? 'item-' + i : item.id,
      item,
      props: rest,
      empty: Boolean(item.empty),
      disabled: Boolean(item.disabled),
    })
  }
  for (let i = out.length; i < props.slots; i += 1) {
    out.push({ id: '__empty-' + i, item: null, props: { empty: true }, empty: true, disabled: false })
  }
  return out
})

const gridStyle = computed(() => ({
  gridTemplateColumns: 'repeat(' + Math.max(1, props.columns) + ', minmax(0, 1fr))',
  gap: props.gap + 'px',
}))

const els = []
const focusIndex = ref(0)

function setEl(el, i) {
  els[i] = el && el.$el ? el.$el : el
}

const activeIndex = computed(() => {
  const i = cells.value.findIndex((c) => !c.empty && c.id === selected.value)
  return i === -1 ? Math.min(focusIndex.value, Math.max(0, cells.value.length - 1)) : i
})

function focusCell(i) {
  const len = cells.value.length
  if (len === 0) return
  const next = Math.min(Math.max(i, 0), len - 1)
  focusIndex.value = next
  const el = els[next]
  if (el && typeof el.focus === 'function') el.focus()
}

function pick(cell) {
  if (!cell || cell.empty || cell.disabled) return
  selected.value = cell.id
  emit('select', cell.item)
}

// 2D roving: left/right walk the row and spill over into the next one, up/down jump a full row.
function onKeydown(event) {
  const len = cells.value.length
  if (len === 0) return
  const cols = Math.max(1, props.columns)
  const i = focusIndex.value
  let next = null
  if (event.key === 'ArrowRight') next = i + 1
  else if (event.key === 'ArrowLeft') next = i - 1
  else if (event.key === 'ArrowDown') next = i + cols
  else if (event.key === 'ArrowUp') next = i - cols
  else if (event.key === 'Home') next = 0
  else if (event.key === 'End') next = len - 1
  if (next === null) return
  if (next < 0 || next >= len) return
  event.preventDefault()
  focusCell(next)
}
</script>

<template>
  <div class="core-slotgrid" :style="gridStyle" role="grid" @keydown="onKeydown">
    <CoreSlot
      v-for="(cell, i) in cells"
      :key="cell.id"
      :ref="(el) => setEl(el, i)"
      v-bind="cell.props"
      :ratio="cell.props.ratio || ratio"
      :selected="!cell.empty && cell.id === selected"
      :tabindex="i === activeIndex ? 0 : -1"
      @focus="focusIndex = i"
      @click="pick(cell)"
    >
      <slot name="slot" :item="cell.item" />
    </CoreSlot>
  </div>
</template>
