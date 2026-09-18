<script setup>
// CoreList — the quest list of mockup 4 (DESIGN §37.5, Game).
// Root class `core-listview`, NOT `core-list`: that legacy name is the old menu <ul> and stays
// with css/navigation.css. Cards with a gap by default; `dividers` collapses them into one
// hairline-separated list. ONE tab stop, ↑/↓ rove, Enter/Space select (the rows are buttons).
import { computed, ref } from 'vue'

const props = defineProps({
  /** `[{ id, image?, icon?, iconTone?, title?, subtitle?, trailing?, completed?, disabled? }]`. */
  items: { type: Array, default: () => [] },
  /** Hairlines between rows instead of gaps — never around the selected card. */
  dividers: { type: Boolean, default: false },
})

/** `v-model` — the id of the selected row. */
const selected = defineModel({ type: [String, Number], default: null })
const emit = defineEmits(['select'])

const rows = computed(() => {
  const list = Array.isArray(props.items) ? props.items : []
  return list.map((raw, i) => {
    const item = raw || {}
    const rest = Object.assign({}, item)
    delete rest.id
    return {
      id: item.id === undefined || item.id === null ? 'row-' + i : item.id,
      item,
      props: rest,
      disabled: Boolean(item.disabled),
    }
  })
})

const els = []
const focusIndex = ref(0)

function setEl(el, i) {
  els[i] = el && el.$el ? el.$el : el
}

const activeIndex = computed(() => {
  const i = rows.value.findIndex((row) => row.id === selected.value)
  return i === -1 ? Math.min(focusIndex.value, Math.max(0, rows.value.length - 1)) : i
})

function focusRow(i) {
  const len = rows.value.length
  if (len === 0) return
  const next = Math.min(Math.max(i, 0), len - 1)
  focusIndex.value = next
  const el = els[next]
  if (el && typeof el.focus === 'function') el.focus()
}

function pick(row) {
  if (!row || row.disabled) return
  selected.value = row.id
  emit('select', row.item)
}

function onKeydown(event) {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp' && event.key !== 'Home' && event.key !== 'End') return
  const len = rows.value.length
  if (len === 0) return
  event.preventDefault()
  if (event.key === 'Home') return focusRow(0)
  if (event.key === 'End') return focusRow(len - 1)
  focusRow(focusIndex.value + (event.key === 'ArrowDown' ? 1 : -1))
}
</script>

<template>
  <div
    class="core-listview"
    :class="{ 'core-listview--dividers': dividers }"
    role="listbox"
    @keydown="onKeydown"
  >
    <template v-for="(row, i) in rows" :key="row.id">
      <slot name="item" :item="row.item" :selected="row.id === selected" :index="i">
        <CoreListItem
          :ref="(el) => setEl(el, i)"
          v-bind="row.props"
          :selected="row.id === selected"
          :tabindex="i === activeIndex ? 0 : -1"
          role="option"
          :aria-selected="row.id === selected ? 'true' : 'false'"
          @focus="focusIndex = i"
          @click="pick(row)"
        />
      </slot>
    </template>
  </div>
</template>
