<script setup>
// CoreHotbar — the four HUD cells of mockup 2 (DESIGN §37.5, Game).
// Same CoreSlot as the inventory grid, but over the bare game: fixed-width cells, the 5 / 4
// landscape ratio, a key cap in every corner and the panel fill the partial adds under
// `.core-hotbar .core-slot`. `active` is an INDEX (the key the player pressed), not an id.
import { computed, ref } from 'vue'

const props = defineProps({
  /** `[{ image?, icon?, count?, rarity?, durability?, badge?, disabled?, hotkey?, … }]`. */
  items: { type: Array, default: () => [] },
  /** Index of the cell the player has drawn; -1 for none. */
  active: { type: Number, default: -1 },
  /** Key cap labels. Null: `1`…`n`. An item's own `hotkey` still wins. */
  keys: { type: Array, default: null },
  /** Cell width in px. */
  slotWidth: { type: Number, default: 96 },
  ratio: { type: String, default: '5 / 4' },
})

const emit = defineEmits(['select'])

const cells = computed(() => {
  const list = Array.isArray(props.items) ? props.items : []
  return list.map((raw, i) => {
    const item = raw || {}
    const rest = Object.assign({}, item)
    delete rest.id
    if (rest.hotkey === undefined || rest.hotkey === null || rest.hotkey === '') {
      rest.hotkey = props.keys && props.keys[i] !== undefined ? props.keys[i] : i + 1
    }
    return { key: item.id === undefined || item.id === null ? 'slot-' + i : item.id, item, props: rest }
  })
})

// One tab stop for the whole belt, the same roving model CoreSlotGrid uses — without it every
// cell is its own tab stop and Tab walks the HUD instead of the page.
const els = []
const focusIndex = ref(0)

function setEl(el, i) {
  els[i] = el && el.$el ? el.$el : el
}

const tabIndex = computed(() => {
  const len = cells.value.length
  if (len === 0) return 0
  if (props.active >= 0 && props.active < len) return props.active
  return Math.min(focusIndex.value, len - 1)
})

function focusCell(i) {
  const len = cells.value.length
  if (len === 0) return
  const next = Math.min(Math.max(i, 0), len - 1)
  focusIndex.value = next
  const el = els[next]
  if (el && typeof el.focus === 'function') el.focus()
}

function onKeydown(event) {
  const len = cells.value.length
  if (len === 0) return
  let next = null
  if (event.key === 'ArrowRight') next = focusIndex.value + 1
  else if (event.key === 'ArrowLeft') next = focusIndex.value - 1
  else if (event.key === 'Home') next = 0
  else if (event.key === 'End') next = len - 1
  if (next === null || next < 0 || next >= len) return
  event.preventDefault()
  focusCell(next)
}

// Enter and Space need no handler: the cells are real <button>s, so they fire `click` themselves.
function pick(cell, i) {
  if (cell.props.disabled) return
  emit('select', i, cell.item)
}
</script>

<template>
  <div class="core-hotbar" role="toolbar" @keydown="onKeydown">
    <CoreSlot
      v-for="(cell, i) in cells"
      :key="cell.key"
      :ref="(el) => setEl(el, i)"
      v-bind="cell.props"
      :size="slotWidth"
      :ratio="cell.props.ratio || ratio"
      :selected="i === active"
      :tabindex="i === tabIndex ? 0 : -1"
      @focus="focusIndex = i"
      @click="pick(cell, i)"
    />
  </div>
</template>
