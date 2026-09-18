<script setup>
// CoreMenu — the vertical menu (DESIGN §37.5, Navigation): the main menu, a category sidebar and
// the shell's keyboard menu are all this component at three sizes.
//
// `v-model` is the ACTIVE row, not a "chosen" one: ↑/↓ only move it (skipping disabled rows via
// nextEnabledIndex), and `select` fires separately on Enter/Space or a click — that split is what
// lets a main menu highlight a row while the player is still deciding. With no `v-model` bound the
// value stays local and starts on the first enabled row. Roving tabindex: one tab stop, focus
// follows the active row so Enter always acts on what is lit.
// `select` carries the normalised item; the value comes back through `update:modelValue`.
// `keyboard: false` + `rowAttrs` exist for the shell's keyboard menu (§37.6): it owns ↑/↓/Enter on
// `window` and needs its own hooks (`data-index`, `aria-selected`) on the rows; both default to
// today's behaviour.
// `item.glyph` is the other half of that: Lua's `menu:open` lets a plugin put ANY short text in an
// item's `icon` (an emoji, a letter), which is not a registry name and has no path — the shell
// routes such a string to `glyph` and it is drawn as text in the same icon box.
import { computed, useTemplateRef } from 'vue'
import { SIZES, oneOf, normalizeItems, nextEnabledIndex } from '../use.js'

// The box the glyph is drawn into, matching --core-menu-icon in css/navigation.css: a size up from
// the mark sizes §37.5 quotes, because an MDI path only fills about 75 % of its 24-grid.
const ICON_PX = { sm: 22, md: 30, lg: 34 }

const props = defineProps({
  /** `[{ value, label, icon?, glyph?, description?, trailing?, badge?, disabled?, danger? }]`. */
  items: { type: Array, default: () => [] },
  /** Row height 38 / 56 / 70 px, label 15 / 18 / 25 px. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** The active row dissolves into the panel on the right (the mockups). `false` = solid coral. */
  fade: { type: Boolean, default: true },
  /** Pointing at a row makes it active — the main-menu feel. */
  selectOnHover: { type: Boolean, default: false },
  /** ↑/↓ wrap around the ends. */
  loop: { type: Boolean, default: true },
  /** false: no arrow/Home/End handling here — the caller moves `v-model` itself. */
  keyboard: { type: Boolean, default: true },
  /** `(item, index) => ({ … })`: attributes merged onto that row's button (class merges, too). */
  rowAttrs: { type: Function, default: null },
})

const emit = defineEmits(['select'])
const model = defineModel()
const rootEl = useTemplateRef('rootEl')

const list = computed(() => normalizeItems(props.items))

const fallback = computed(() => {
  const i = list.value.findIndex((item) => !item.disabled)
  return i === -1 ? undefined : list.value[i].value
})
const activeIndex = computed(() => {
  const i = list.value.findIndex((item) => item.value === model.value)
  return i === -1 ? list.value.findIndex((item) => item.value === fallback.value) : i
})

const rootClass = computed(() => ['core-menu--' + props.size, { 'is-fade': props.fade }])
// One entry per row. The getter calls rowAttrs(), so whatever reactive state the caller reads in
// there (its own selection, for one) re-renders the rows the same way the internal state does.
const rowBind = computed(() => (typeof props.rowAttrs === 'function'
  ? list.value.map((item, i) => props.rowAttrs(item, i) || {})
  : list.value.map(() => ({}))))
const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)

function setActive (index) {
  const item = list.value[index]
  if (!item || item.disabled || index === activeIndex.value) return
  model.value = item.value
}

function focusAt (index) {
  const el = rootEl.value && rootEl.value.children ? rootEl.value.children[index] : null
  if (el && typeof el.focus === 'function') el.focus()
}

/** `edge` = Home/End: start outside the list so the first/last enabled row wins. */
function move (dir, edge = false) {
  const from = edge ? (dir < 0 ? list.value.length : -1) : activeIndex.value
  const next = nextEnabledIndex(list.value, from, dir, edge ? false : props.loop)
  if (next === from || next < 0) return
  setActive(next)
  focusAt(next)
}

function choose (index) {
  const item = list.value[index]
  if (!item || item.disabled) return
  setActive(index)
  emit('select', item)
}

function onHover (index) {
  if (props.selectOnHover) setActive(index)
}

function onKeydown (event) {
  if (!props.keyboard) return
  const key = event.key
  if (key === 'ArrowDown' || key === 'ArrowRight') move(1)
  else if (key === 'ArrowUp' || key === 'ArrowLeft') move(-1)
  else if (key === 'Home') move(1, true)
  else if (key === 'End') move(-1, true)
  else return
  event.preventDefault()
}

const hasBadge = (item) => item.badge !== undefined && item.badge !== null && item.badge !== ''
const hasGlyph = (item) => item.glyph !== undefined && item.glyph !== null && item.glyph !== ''
</script>

<template>
  <div ref="rootEl" class="core-menu" :class="rootClass" role="menu" @keydown="onKeydown">
    <button
      v-for="(item, i) in list"
      :key="i"
      type="button"
      role="menuitem"
      class="core-menu__item"
      :class="{
        'is-active': i === activeIndex,
        'is-disabled': !!item.disabled,
        'is-danger': !!item.danger,
      }"
      :disabled="!!item.disabled"
      :tabindex="i === activeIndex ? 0 : -1"
      :aria-current="i === activeIndex ? 'true' : null"
      v-bind="rowBind[i]"
      @click="choose(i)"
      @mouseenter="onHover(i)"
    >
      <slot name="item" :item="item" :active="i === activeIndex">
        <span v-if="item.icon" class="core-menu__icon">
          <CoreIcon :name="item.icon" :size="iconPx" />
        </span>
        <span v-else-if="hasGlyph(item)" class="core-menu__icon core-menu__icon--glyph">{{ item.glyph }}</span>
        <span class="core-menu__body">
          <span class="core-menu__label">{{ item.label }}</span>
          <span v-if="item.description" class="core-menu__desc">{{ item.description }}</span>
        </span>
        <span v-if="hasBadge(item)" class="core-menu__badge">{{ item.badge }}</span>
      </slot>
      <span v-if="$slots.trailing || item.trailing" class="core-menu__trailing">
        <slot name="trailing" :item="item" :active="i === activeIndex">{{ item.trailing }}</slot>
      </span>
    </button>
  </div>
</template>
