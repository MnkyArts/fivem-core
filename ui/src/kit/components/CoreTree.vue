<script setup>
// CoreTree — nested rows with expand / collapse and selection (DESIGN §53, §37.5 Data — display).
// The nested `items` are FLATTENED into the rows that are visible right now (every ancestor
// expanded) and those go through CoreVirtualList, so an outliner with thousands of elements costs
// only the rows on screen. The root is the one tab stop (`role="tree"`) and drives a roving cursor
// with aria-activedescendant — focus never moves into a row, exactly like CoreSelect's list.
// Keyboard (WAI-ARIA tree): ↑/↓ move, → expands or steps into the first child, ← collapses or
// steps out to the parent, Home/End jump, Enter selects, Space toggles in `multiple`. Mouse: click
// selects (Ctrl/⌘-click toggles and Shift-click selects a range when `multiple`), a double click
// emits `activate`, the chevron only toggles.
import { computed, nextTick, ref, watch } from 'vue'
import { useId } from '../use.js'

const props = defineProps({
  /** `[{ id, label, icon?, badge?, description?, disabled?, children?: [...] }]` */
  items: { type: Array, default: () => [] },
  /** Which field identifies a node (`value` is used when it is missing). */
  keyField: { type: String, default: 'id' },
  /** Which field holds a node's children. */
  childrenField: { type: String, default: 'children' },
  /** `v-model` becomes an array of keys; Ctrl-click / Shift-click / Space extend it. */
  multiple: { type: Boolean, default: false },
  /** 28 px rows instead of 32 px. */
  dense: { type: Boolean, default: false },
  /** Indentation per level, in px. */
  indent: { type: Number, default: 16 },
  /** Rows beyond the viewport kept alive by CoreVirtualList. */
  overscan: { type: Number, default: 8 },
  disabled: { type: Boolean, default: false },
  /** The line shown when `items` is empty; the `empty` slot replaces it. */
  empty: { type: String, default: 'Nothing here.' },
  /** Accessible name of the tree. */
  label: { type: String, default: '' },
})

const emit = defineEmits(['select', 'toggle', 'activate'])

/** The selected key (or keys, with `multiple`). */
const model = defineModel({ type: null, default: null })
/** The expanded keys (`v-model:expanded`); uncontrolled when not bound. */
const expanded = defineModel('expanded', { type: Array, default: () => [] })

const listRef = ref(null)
const activeKey = ref(null)
const anchorKey = ref(null)
const treeId = useId('core-tree')

const rowHeight = computed(() => (props.dense ? 28 : 32))
const keyOf = (node, path) => {
  if (node && node[props.keyField] !== undefined) return node[props.keyField]
  if (node && node.value !== undefined) return node.value
  return path
}
const childrenOf = (node) => {
  const c = node ? node[props.childrenField] : null
  return Array.isArray(c) ? c : []
}

const expandedSet = computed(() => new Set(Array.isArray(expanded.value) ? expanded.value : []))
const selectedSet = computed(() => {
  const v = model.value
  if (props.multiple) return new Set(Array.isArray(v) ? v : [])
  return new Set(v === null || v === undefined ? [] : [v])
})

/** The visible rows, in order: `{ node, key, depth, parentKey, hasChildren, open, posinset, setsize }`. */
const flat = computed(() => {
  const out = []
  const walk = (list, depth, parentKey, prefix) => {
    for (let i = 0; i < list.length; i += 1) {
      const node = list[i]
      if (!node || typeof node !== 'object') continue
      const key = keyOf(node, prefix + i)
      const kids = childrenOf(node)
      const open = kids.length > 0 && expandedSet.value.has(key)
      out.push({ node, key, depth, parentKey, hasChildren: kids.length > 0, open, posinset: i + 1, setsize: list.length })
      if (open) walk(kids, depth + 1, key, prefix + i + '.')
    }
  }
  walk(Array.isArray(props.items) ? props.items : [], 0, null, '')
  return out
})

const indexOfKey = (key) => flat.value.findIndex((row) => row.key === key)
const rowId = (index) => treeId + '-' + index
const activeIndex = computed(() => indexOfKey(activeKey.value))

function setExpanded (key, open) {
  const set = new Set(expandedSet.value)
  if (open) set.add(key)
  else set.delete(key)
  expanded.value = Array.from(set)
}

function toggle (row, open) {
  if (!row || !row.hasChildren) return
  const next = open === undefined ? !row.open : open
  if (next === row.open) return
  setExpanded(row.key, next)
  emit('toggle', row.node, next)
}

function reveal (index) {
  nextTick(() => { if (listRef.value) listRef.value.scrollToIndex(index) })
}

function moveTo (index) {
  const row = flat.value[index]
  if (!row) return
  activeKey.value = row.key
  reveal(index)
}

/** Selection: `mode` = 'replace' | 'toggle' | 'range'. */
function select (row, mode) {
  if (!row || props.disabled || row.node.disabled) return
  activeKey.value = row.key
  if (!props.multiple) {
    model.value = row.key
    anchorKey.value = row.key
    emit('select', row.node)
    return
  }
  const current = Array.isArray(model.value) ? model.value.slice() : []
  if (mode === 'toggle') {
    const at = current.indexOf(row.key)
    if (at === -1) current.push(row.key)
    else current.splice(at, 1)
    model.value = current
    anchorKey.value = row.key
  } else if (mode === 'range' && anchorKey.value !== null && indexOfKey(anchorKey.value) !== -1) {
    const a = indexOfKey(anchorKey.value)
    const b = indexOfKey(row.key)
    const keys = []
    for (let i = Math.min(a, b); i <= Math.max(a, b); i += 1) {
      if (!flat.value[i].node.disabled) keys.push(flat.value[i].key)
    }
    model.value = keys
  } else {
    model.value = [row.key]
    anchorKey.value = row.key
  }
  emit('select', row.node)
}

function onRowClick (row, event) {
  if (props.multiple && (event.ctrlKey || event.metaKey)) select(row, 'toggle')
  else if (props.multiple && event.shiftKey) select(row, 'range')
  else select(row, 'replace')
}

function onRowDblclick (row) {
  if (props.disabled || row.node.disabled) return
  emit('activate', row.node)
}

/** Tabbing in parks the cursor on the first selected row (else the top) WITHOUT scrolling: a click
 *  focuses the root on mousedown, and scrolling then would move another row under the pointer. */
function onFocus () {
  if (activeIndex.value !== -1 || flat.value.length === 0) return
  const firstSelected = flat.value.findIndex((row) => selectedSet.value.has(row.key))
  activeKey.value = flat.value[firstSelected === -1 ? 0 : firstSelected].key
}

function onKeydown (event) {
  if (props.disabled || flat.value.length === 0) return
  const i = activeIndex.value === -1 ? 0 : activeIndex.value
  const row = flat.value[i]
  const key = event.key
  if (key === 'ArrowDown') moveTo(Math.min(flat.value.length - 1, activeIndex.value === -1 ? 0 : i + 1))
  else if (key === 'ArrowUp') moveTo(Math.max(0, i - 1))
  else if (key === 'Home') moveTo(0)
  else if (key === 'End') moveTo(flat.value.length - 1)
  else if (key === 'ArrowRight') {
    if (row.hasChildren && !row.open) toggle(row, true)
    else if (row.open) moveTo(i + 1)
  } else if (key === 'ArrowLeft') {
    if (row.open) toggle(row, false)
    else if (row.parentKey !== null) moveTo(indexOfKey(row.parentKey))
  } else if (key === 'Enter') select(row, 'replace')
  else if (key === ' ') select(row, props.multiple ? 'toggle' : 'replace')
  else return
  event.preventDefault()
}

// A cursor on a row that just disappeared (an ancestor collapsed, the data changed) climbs to its
// nearest visible ancestor, else the top. The parent map walks the WHOLE tree, so it is only
// built on that rare path.
watch(flat, (rows) => {
  if (activeKey.value === null || indexOfKey(activeKey.value) !== -1) return
  const parents = new Map()
  const walk = (list, parentKey, prefix) => {
    for (let i = 0; i < list.length; i += 1) {
      const node = list[i]
      if (!node || typeof node !== 'object') continue
      const key = keyOf(node, prefix + i)
      parents.set(key, parentKey)
      walk(childrenOf(node), key, prefix + i + '.')
    }
  }
  walk(Array.isArray(props.items) ? props.items : [], null, '')
  let key = parents.has(activeKey.value) ? parents.get(activeKey.value) : null
  while (key !== null && key !== undefined && indexOfKey(key) === -1) key = parents.get(key)
  activeKey.value = key !== null && key !== undefined ? key : (rows.length ? rows[0].key : null)
})

const rowStyle = (row) => ({ paddingLeft: 6 + row.depth * props.indent + 'px' })
</script>

<template>
  <div
    class="core-tree"
    :class="{ 'core-tree--dense': dense, 'is-disabled': disabled, 'is-multiple': multiple }"
    role="tree"
    :tabindex="disabled ? -1 : 0"
    :aria-label="label || undefined"
    :aria-multiselectable="multiple ? 'true' : undefined"
    :aria-activedescendant="activeIndex >= 0 ? rowId(activeIndex) : undefined"
    :aria-disabled="disabled ? 'true' : undefined"
    @focus="onFocus"
    @keydown="onKeydown"
  >
    <CoreVirtualList
      ref="listRef"
      class="core-tree__list"
      role="presentation"
      :items="flat"
      :item-height="rowHeight"
      key-field="key"
      :overscan="overscan"
    >
      <template #default="{ item: row, index }">
        <div
          :id="rowId(index)"
          class="core-tree__row"
          :class="{
            'is-selected': selectedSet.has(row.key),
            'is-active': index === activeIndex,
            'is-open': row.open,
            'is-disabled': row.node.disabled,
            'has-children': row.hasChildren,
          }"
          :style="rowStyle(row)"
          role="treeitem"
          :aria-level="row.depth + 1"
          :aria-posinset="row.posinset"
          :aria-setsize="row.setsize"
          :aria-expanded="row.hasChildren ? (row.open ? 'true' : 'false') : undefined"
          :aria-selected="selectedSet.has(row.key) ? 'true' : 'false'"
          :aria-disabled="row.node.disabled ? 'true' : undefined"
          @click="onRowClick(row, $event)"
          @dblclick="onRowDblclick(row)"
        >
          <span
            class="core-tree__twisty"
            :class="{ 'is-hidden': !row.hasChildren }"
            aria-hidden="true"
            @click.stop="toggle(row)"
          >
            <CoreIcon name="chevron-right" size="sm" />
          </span>
          <span v-if="row.node.icon || $slots.icon" class="core-tree__icon">
            <slot name="icon" :node="row.node" :open="row.open" :depth="row.depth">
              <CoreIcon :name="row.node.icon" size="sm" />
            </slot>
          </span>
          <span class="core-tree__label">
            <slot name="label" :node="row.node" :depth="row.depth">{{ row.node.label }}</slot>
          </span>
          <span v-if="row.node.badge !== undefined && row.node.badge !== null && row.node.badge !== ''" class="core-tree__badge">
            <slot name="badge" :node="row.node">{{ row.node.badge }}</slot>
          </span>
          <span v-if="$slots.trailing" class="core-tree__trailing" @click.stop @mousedown.stop>
            <slot
              name="trailing"
              :node="row.node"
              :depth="row.depth"
              :open="row.open"
              :selected="selectedSet.has(row.key)"
            />
          </span>
        </div>
      </template>
      <template #empty>
        <slot name="empty"><p class="core-tree__empty">{{ empty }}</p></slot>
      </template>
    </CoreVirtualList>
  </div>
</template>
