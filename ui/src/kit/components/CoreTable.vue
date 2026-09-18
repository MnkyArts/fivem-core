<script setup>
// CoreTable — rows of data (DESIGN §37.5, Data — display).
// A real <table>: a column keeps its width across every row without a grid, and the browser handles
// the shrinking. The ROOT is the scroll wrapper, not the table, because `stickyHeader` needs a
// scroll container and the caller's max-height has to land on it (`<CoreTable style="max-height:…">`).
// Selection is `v-model:selected` on the ROW KEY, never on the index: rows get re-sorted.
import { computed, ref } from 'vue'

const ALIGNS = ['left', 'center', 'right']

const props = defineProps({
  /** `[{ key, label, align?: 'left'|'center'|'right', width?, format?(value, row) }]` */
  columns: { type: Array, default: () => [] },
  /** The data. Anything array-like of plain objects. */
  rows: { type: Array, default: () => [] },
  /** Which field identifies a row. */
  rowKey: { type: String, default: 'id' },
  /** Rows highlight and answer ↑/↓ + Enter. */
  selectable: { type: Boolean, default: false },
  /** 36 px rows instead of 44 px. */
  dense: { type: Boolean, default: false },
  /** Header sticks while the wrapper scrolls — give the wrapper a max-height. */
  stickyHeader: { type: Boolean, default: false },
  /** The line shown when `rows` is empty; the `empty` slot replaces it. */
  empty: { type: String, default: 'Nothing to show.' },
})

const emit = defineEmits(['row-click'])

/** The selected ROW KEY (`v-model:selected`), not the index. */
const selected = defineModel('selected', { type: [String, Number, null], default: null })

const body = ref(null)

const keyOf = (row, i) => (row && row[props.rowKey] !== undefined ? row[props.rowKey] : i)

const cellValue = (row, column) => {
  const raw = row ? row[column.key] : undefined
  if (typeof column.format === 'function') return column.format(raw, row)
  return raw === null || raw === undefined ? '' : raw
}

const colStyle = (column) => {
  if (column.width === undefined || column.width === null || column.width === '') return null
  return { width: typeof column.width === 'number' ? column.width + 'px' : String(column.width) }
}

const alignOf = (column) => (ALIGNS.indexOf(column.align) === -1 ? 'left' : column.align)

const rootClass = computed(() => ['core-table__wrap', 'core-scroll', { 'is-sticky': props.stickyHeader }])
const tableClass = computed(() => ['core-table', {
  'core-table--dense': props.dense,
  'is-selectable': props.selectable,
}])

function pick(row, i) {
  if (props.selectable) selected.value = keyOf(row, i)
  emit('row-click', row)
}

/** ↑/↓ move the selection (Home/End jump), Enter opens the selected row. */
function onKeydown(event) {
  if (!props.selectable || props.rows.length === 0) return
  const current = props.rows.findIndex((row, i) => keyOf(row, i) === selected.value)
  let next = current
  if (event.key === 'ArrowDown') next = Math.min(props.rows.length - 1, current + 1)
  else if (event.key === 'ArrowUp') next = current <= 0 ? 0 : current - 1
  else if (event.key === 'Home') next = 0
  else if (event.key === 'End') next = props.rows.length - 1
  else if (event.key === 'Enter' || event.key === ' ') {
    if (current === -1) return
    event.preventDefault()
    emit('row-click', props.rows[current])
    return
  } else return
  event.preventDefault()
  selected.value = keyOf(props.rows[next], next)
}
</script>

<template>
  <div :class="rootClass">
    <table :class="tableClass">
      <thead>
        <tr>
          <th
            v-for="column in columns"
            :key="column.key"
            class="core-table__th"
            :class="'core-table__th--' + alignOf(column)"
            :style="colStyle(column)"
            scope="col"
          >{{ column.label }}</th>
        </tr>
      </thead>

      <tbody
        ref="body"
        class="core-table__body"
        :tabindex="selectable ? 0 : null"
        @keydown="onKeydown"
      >
        <tr
          v-for="(row, i) in rows"
          :key="keyOf(row, i)"
          class="core-table__row"
          :class="{ 'is-selected': selectable && keyOf(row, i) === selected }"
          :aria-selected="selectable ? keyOf(row, i) === selected : null"
          @click="pick(row, i)"
        >
          <td
            v-for="column in columns"
            :key="column.key"
            class="core-table__cell"
            :class="'core-table__cell--' + alignOf(column)"
          >
            <slot :name="'cell-' + column.key" :row="row" :value="cellValue(row, column)" :column="column">
              {{ cellValue(row, column) }}
            </slot>
          </td>
        </tr>

        <tr v-if="rows.length === 0" class="core-table__empty">
          <td class="core-table__cell" :colspan="Math.max(1, columns.length)">
            <slot name="empty"><p>{{ empty }}</p></slot>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
