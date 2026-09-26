<script setup>
// Centred keyboard menu (DESIGN §6.10 `menu:open`, §7.3, §37.6): a CoreDialog around a CoreMenu.
// store.js owns Escape (-> menuResult(null)), so the dialog registers no Escape layer
// (`:escape="false"`) and takes no focus (`:trap="false"`); this component owns Up/Down/Enter on
// `window` (`:keyboard="false"` on CoreMenu keeps it the only owner) and the mouse.
// Kit components are imported by path, never relied on through the global registration, so the
// shell cannot depend on install order (§37.6).
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, menuResult, menuChange, activeModal, setMenuBackHandler } from '../store.js'
import CoreDialog from '../kit/components/CoreDialog.vue'
import CoreMenu from '../kit/components/CoreMenu.vue'
import CoreButton from '../kit/components/CoreButton.vue'
import CoreProgress from '../kit/components/CoreProgress.vue'
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
const levels = ref([])
let changing = null
const visible = computed(() => store.menu.visible)
const items = computed(() => levels.value.length ? levels.value[levels.value.length - 1].items : (Array.isArray(store.menu.items) ? store.menu.items : []))
const currentItem = computed(() => items.value[selected.value])
const title = computed(() => levels.value.length ? levels.value[levels.value.length - 1].title : (store.menu.title || 'Menu'))
const metadata = computed(() => Array.isArray(currentItem.value?.metadata) ? currentItem.value.metadata : [])
function sideLabel (item) {
  const value = item.values?.[(item.selected || 1) - 1]
  return value && typeof value === 'object' ? value.label : value
}
function adjust (direction) {
  const item = currentItem.value
  if (!item || item.disabled || !Array.isArray(item.values) || !item.values.length) return
  const next = ((item.selected || 1) - 1 + direction + item.values.length) % item.values.length + 1
  change(item, { selected: next })
}
async function change (item, values) {
  if (changing) return
  const id = store.menu.id
  const task = menuChange(item.value, values)
  changing = task
  try {
    if (await task && store.menu.visible && store.menu.id === id) Object.assign(item, values)
  } finally {
    if (changing === task) changing = null
  }
}
function back () {
  if (!levels.value.length) return false
  const previous = levels.value.pop()
  select(previous.selected)
  return true
}

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
      trailing: item?.items?.length ? '›' : (typeof item?.checked === 'boolean' ? (item.checked ? '☑' : '☐') : (item?.values?.length ? '‹ ' + sideLabel(item) + ' ›' : undefined)),
    }
  })
  : [{ value: 0, label: 'No entries', disabled: true }]))

/** The hooks the regression suite and the stories read, on the row the kit draws. */
function rowAttrs (row, i) {
  return {
    'data-index': i,
    'aria-selected': i === selected.value ? 'true' : 'false',
    'aria-disabled': row.disabled ? 'true' : null,
    role: typeof items.value[i]?.checked === 'boolean' ? 'menuitemcheckbox' : 'menuitem',
    'aria-checked': typeof items.value[i]?.checked === 'boolean' ? String(items.value[i].checked) : null,
    'aria-haspopup': items.value[i]?.items?.length ? 'menu' : null,
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
  if (changing) return
  const it = items.value[i]
  if (!it || it.disabled) return
  if (Array.isArray(it.items) && it.items.length) {
    levels.value.push({ title: it.label, items: it.items, selected: i })
    select(usable(0) ? 0 : step(0, 1)); return
  }
  if (typeof it.checked === 'boolean') {
    change(it, { checked: !it.checked }); return
  }
  // `undefined` would reach Lua as nil (= cancelled), so fall back to the index.
  menuResult(it.value !== undefined ? it.value : i)
}

function onKeydown (e) {
  if (activeModal() !== 'menu' || e.defaultPrevented) return
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault()
    select(step(selected.value, e.key === 'ArrowDown' ? 1 : -1))
  } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    e.preventDefault(); adjust(e.key === 'ArrowRight' ? 1 : -1)
  } else if (e.key === 'Enter') {
    e.preventDefault()
    choose(selected.value)
  }
}

watch([visible, () => store.menu.id], ([open]) => {
  changing = null
  levels.value = []
  if (open) select(usable(0) ? 0 : step(0, 1))
}, { immediate: true })

let releaseBack = null
onMounted(() => { window.addEventListener('keydown', onKeydown); releaseBack = setMenuBackHandler(back) })
onBeforeUnmount(() => { window.removeEventListener('keydown', onKeydown); releaseBack?.() })
</script>

<template>
  <div ref="root">
    <!-- The rows are full-bleed inside the panel, so the menu cancels the dialog body's own
         padding with margins and keeps the 6 px the list had under its last row. -->
    <CoreDialog
      class="menu"
      :open="visible"
      :title="title"
      :closable="false"
      :escape="false"
      :trap="false"
      :teleport="false"
    >
      <CoreButton v-if="levels.length" size="sm" @click="back">Back</CoreButton>
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
      <div v-if="currentItem?.values?.length" class="flex items-center justify-between mt-5" aria-label="Change selection">
        <CoreButton size="sm" aria-label="Previous value" @click="adjust(-1)">‹</CoreButton>
        <span class="core-text">{{ sideLabel(currentItem) }}</span>
        <CoreButton size="sm" aria-label="Next value" @click="adjust(1)">›</CoreButton>
      </div>
      <dl v-if="metadata.length" class="mt-5 text-sm">
        <div v-for="(entry, i) in metadata" :key="i" class="flex justify-between gap-4">
          <dt>{{ typeof entry === 'object' ? entry.label : entry }}</dt>
          <dd>{{ typeof entry === 'object' ? entry.value : '' }}</dd>
        </div>
      </dl>
      <CoreProgress v-if="typeof currentItem?.progress === 'number'" class="mt-5" :value="currentItem.progress" show-value />
      <template #footer>
        <CoreKeyHints class="hint" :items="HINTS" align="end" size="sm" bare />
      </template>
    </CoreDialog>
  </div>
</template>
