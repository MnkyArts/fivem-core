<script setup>
// Centred keyboard menu (DESIGN §6.10 `menu:open`, §7.3, §37.6): a CoreDialog around a CoreMenu.
// store.js owns Escape (-> menuResult(null)), so the dialog registers no Escape layer
// (`:escape="false"`) and takes no focus (`:trap="false"`); this component owns Up/Down/Enter on
// `window` (`:keyboard="false"` on CoreMenu keeps it the only owner) and the mouse.
// Kit components are imported by path, never relied on through the global registration, so the
// shell cannot depend on install order (§37.6).
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, menuResult, activeModal } from '../store.js'
import CoreDialog from '../kit/components/CoreDialog.vue'
import CoreMenu from '../kit/components/CoreMenu.vue'
import CoreKeyHints from '../kit/components/CoreKeyHints.vue'
import { iconPath } from '../kit/icons.js'

// The three keys this component and store.js answer to, in the footer's reading order.
const HINTS = [
  { keys: ['↑', '↓'], label: 'Move' },
  { key: 'Enter', label: 'Select' },
  { key: 'Esc', label: 'Close' },
]

const root = ref(null)
const selected = ref(0)
const visible = computed(() => store.menu.visible)
const items = computed(() => (Array.isArray(store.menu.items) ? store.menu.items : []))

// CoreMenu's `value` is the INDEX here: Lua's own `value` may be missing or repeat itself, and the
// index is what every hook (data-index, the Enter handler, the scroll) already speaks. An empty
// menu keeps its one disabled "No entries" row instead of collapsing to nothing.
// Lua's `icon` is whatever the plugin wrote: a registry name, raw path data — or a text mark
// ('⚙', 'A'), which the kit cannot draw as an SVG. `iconPath()` is the arbiter: a string it
// resolves stays `icon`, anything else becomes CoreMenu's `glyph` and is drawn as text (§37.6).
// One item never carries both, so a glyph can never shadow a real icon.
const rows = computed(() => (items.value.length
  ? items.value.map((item, i) => {
    const mark = item && item.icon ? String(item.icon) : ''
    const known = mark !== '' && iconPath(mark) !== ''
    return {
      value: i,
      label: item && item.label !== undefined && item.label !== null ? item.label : '',
      description: item && item.description ? item.description : undefined,
      icon: known ? mark : undefined,
      glyph: !known && mark !== '' ? mark : undefined,
      disabled: !!(item && item.disabled),
    }
  })
  : [{ value: 0, label: 'No entries', disabled: true }]))

/** The hooks the regression suite and the stories read, on the row the kit draws. */
function rowAttrs (row, i) {
  return {
    'data-index': i,
    'aria-selected': i === selected.value ? 'true' : 'false',
    'aria-disabled': row.disabled ? 'true' : null,
  }
}

function usable (i) {
  const it = items.value[i]
  return !!it && !it.disabled
}

/** Next usable index from `from` walking in `dir`, wrapping; `from` itself is skipped. */
function step (from, dir) {
  const n = items.value.length
  if (!n) return 0
  let i = from
  for (let k = 0; k < n; k++) {
    i = ((i + dir) % n + n) % n
    if (usable(i)) return i
  }
  return ((from % n) + n) % n
}

function select (i) {
  selected.value = i
  nextTick(() => {
    const el = root.value && root.value.querySelector('[data-index="' + i + '"]')
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' })
  })
}

function choose (i) {
  const it = items.value[i]
  if (!it || it.disabled) return
  // `undefined` would reach Lua as nil (= cancelled), so fall back to the index.
  menuResult(it.value !== undefined ? it.value : i)
}

function onKeydown (e) {
  if (activeModal() !== 'menu') return
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    select(step(selected.value, e.key === 'ArrowDown' ? 1 : -1))
  } else if (e.key === 'Enter') {
    e.preventDefault()
    choose(selected.value)
  }
}

watch([visible, () => store.menu.id], ([open]) => {
  if (open) select(usable(0) ? 0 : step(0, 1))
})

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <div ref="root">
    <!-- The rows are full-bleed inside the panel, so the menu cancels the dialog body's own
         padding with margins and keeps the 6 px the list had under its last row. -->
    <CoreDialog
      class="menu"
      :open="visible"
      :title="store.menu.title || 'Menu'"
      :closable="false"
      :escape="false"
      :trap="false"
      :teleport="false"
    >
      <CoreMenu
        class="-mx-5 -mb-5 pb-1.5"
        size="sm"
        :items="rows"
        :model-value="selected"
        :row-attrs="rowAttrs"
        :keyboard="false"
        select-on-hover
        @update:model-value="select"
        @select="choose($event.value)"
      />
      <template #footer>
        <CoreKeyHints class="hint" :items="HINTS" align="end" size="sm" bare />
      </template>
    </CoreDialog>
  </div>
</template>
