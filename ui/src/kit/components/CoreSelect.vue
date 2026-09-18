<script setup>
// CoreSelect — the dropdown (DESIGN §37.5, Forms — text).
// Two shapes from one component: `box` is the form control, `inline` is the mockup's chrome-free
// `SORT: RECENT v`. Focus never leaves the trigger — the list is a real `listbox` driven by
// aria-activedescendant, which is why the options are `role="option"` divs that prevent the
// mousedown default instead of buttons. The popup is teleported into #core-overlays (§37.3),
// placed by useFloating, and closed by its own Escape layer so the key never reaches the store.
//
// `placement` has three modes, and the difference is whether the list may move to the other side:
//   'auto'    under the trigger, FLIPPING above when the viewport leaves no room (the form default);
//   'bottom'  pinned under the trigger — it never jumps, even with nothing below it;
//   'top'     pinned above the trigger (a select in a footer bar, over a HUD).
// useFloating always flips, so a pinned mode keeps its `left` (the cross axis is clamped into the
// viewport either way, and is identical on both sides for a `-start` alignment) and recomputes only
// `top` from the live anchor rect.
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import {
  normalizeItems, nextEnabledIndex, oneOf, onClickOutside, overlayTarget, SIZES, useEscapeLayer,
  useFloating, useId,
} from '../use.js'

// A chevron's ink is half its icon box, so these numbers look bigger than they read. Measured off
// the mockup crop: 14.4 px of ink next to 10 px caps, which is a 28 px glyph.
const CHEVRON_BOX = { sm: 18, md: 22, lg: 26 }
const CHEVRON_INLINE = { sm: 22, md: 28, lg: 34 }
const TYPEAHEAD_RESET = 700
const OFFSET = 6

const props = defineProps({
  /** Strings/numbers or `{ value, label, icon?, description?, disabled? }` (normalizeItems). */
  items: { type: Array, default: () => [] },
  /** Shown while nothing is selected. */
  placeholder: { type: String, default: 'Select…' },
  /** Caption before the value — the mockup's `SORT:` (the colon is part of the string). */
  label: { type: String, default: '' },
  variant: { type: String, default: 'box', validator: oneOf(['box', 'inline']) },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** `auto` flips when there is no room; `bottom` and `top` pin to that side (see the header). */
  placement: { type: String, default: 'auto', validator: oneOf(['auto', 'bottom', 'top']) },
  /** Popup height before it scrolls, in px. */
  maxHeight: { type: [String, Number], default: 260 },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  id: { type: String, default: '' },
})

const emit = defineEmits(['open', 'close'])
const model = defineModel({ type: [String, Number, Boolean, Object], default: null })

const open = ref(false)
const activeIndex = ref(-1)
const triggerRef = ref(null)
const popupRef = ref(null)
const listId = useId('core-select-list')

// Never `overlayTarget()` in the template: it CREATES the container when it is missing, so a select
// rendering before #core-overlays exists (it is the last child of .core-root) would build a second
// one on `body` and teleport the popup into that orphan, outside .core-root, where §31 could no
// longer hide it with the shell. Setup does a lookup only — a select that is created already open
// then teleports into the right container on its FIRST render instead of being moved after mount —
// and onMounted is the fallback that resolves (and, only then, creates) it.
const teleportTo = ref((typeof document !== 'undefined' && document.getElementById('core-overlays')) || 'body')
onMounted(() => { teleportTo.value = overlayTarget() || 'body' })

const list = computed(() => normalizeItems(props.items))
const selectedIndex = computed(() => list.value.findIndex((item) => item.value === model.value))
const selected = computed(() => (selectedIndex.value === -1 ? null : list.value[selectedIndex.value]))
const chevronSize = computed(() => (props.variant === 'inline'
  ? CHEVRON_INLINE[props.size] || CHEVRON_INLINE.md
  : CHEVRON_BOX[props.size] || CHEVRON_BOX.md))
const popupStyleOwn = computed(() => ({
  maxHeight: (typeof props.maxHeight === 'number' ? props.maxHeight + 'px' : String(props.maxHeight)),
}))

const { style: floatStyle } = useFloating(triggerRef, popupRef, open, () => ({
  placement: props.placement === 'top' ? 'top-start' : 'bottom-start',
  offset: OFFSET,
  matchWidth: props.variant === 'box',
}))

/* The style the popup actually wears. In `auto` it is useFloating's own result. In a pinned mode
   `top` is re-derived from the anchor here, which undoes a flip useFloating may have made — both
   values are pure functions of the same anchor rect and viewport, so this recomputes exactly when
   useFloating recomputes and never fights it. A pinned list that does not fit stays on its side and
   scrolls inside `maxHeight`; that is the point of pinning. */
const popupStyle = computed(() => {
  const base = Object.assign({}, floatStyle)
  if (props.placement === 'auto') return base
  const anchor = triggerRef.value
  const el = popupRef.value
  if (!anchor || !el) return base
  const rect = anchor.getBoundingClientRect()
  const top = props.placement === 'top' ? rect.top - OFFSET - el.offsetHeight : rect.bottom + OFFSET
  base.top = Math.round(top) + 'px'
  return base
})

useEscapeLayer(open, () => close())
onClickOutside(() => [triggerRef, popupRef], () => close(false), open)

/** The popup is `position: fixed`, so it is its own offsetParent: plain offsetTop math, never
 *  scrollIntoView (which would scroll the page behind the overlay as well). */
function scrollActiveIntoView () {
  const popup = popupRef.value
  if (!popup || activeIndex.value < 0) return
  const el = popup.querySelector('[data-index="' + activeIndex.value + '"]')
  if (!el) return
  const top = el.offsetTop - 4
  const bottom = el.offsetTop + el.offsetHeight + 4
  if (top < popup.scrollTop) popup.scrollTop = top
  else if (bottom > popup.scrollTop + popup.clientHeight) popup.scrollTop = bottom - popup.clientHeight
}

function openList () {
  if (props.disabled || open.value) return
  activeIndex.value = selectedIndex.value !== -1 && !list.value[selectedIndex.value].disabled
    ? selectedIndex.value
    : nextEnabledIndex(list.value, -1, 1, false)
  open.value = true
  emit('open')
  nextTick(scrollActiveIntoView)
}

function close (refocus = true) {
  if (!open.value) return
  open.value = false
  emit('close')
  if (refocus && triggerRef.value) triggerRef.value.focus()
}

function pick (index) {
  const item = list.value[index]
  if (!item || item.disabled) return
  model.value = item.value
  close()
}

function move (dir) {
  const from = activeIndex.value === -1 ? selectedIndex.value : activeIndex.value
  activeIndex.value = nextEnabledIndex(list.value, from, dir, true)
  nextTick(scrollActiveIntoView)
}

let typed = ''
let typedAt = 0

/** Typing jumps to the first label that starts with the buffer (700 ms between keystrokes). */
function typeahead (key) {
  const now = Date.now()
  typed = now - typedAt > TYPEAHEAD_RESET ? key : typed + key
  typedAt = now
  const needle = typed.toLowerCase()
  const index = list.value.findIndex((item) => !item.disabled
    && String(item.label).toLowerCase().indexOf(needle) === 0)
  if (index === -1) return
  activeIndex.value = index
  nextTick(scrollActiveIntoView)
}

function onKeydown (event) {
  if (props.disabled) return
  const key = event.key
  if (!open.value) {
    if (key === 'Enter' || key === ' ' || key === 'ArrowDown' || key === 'ArrowUp') {
      event.preventDefault()
      openList()
      if (key === 'ArrowUp') move(-1)
      return
    }
    if (key.length === 1 && key !== ' ') { openList(); typeahead(key) }
    return
  }
  if (key === 'ArrowDown') { event.preventDefault(); move(1) }
  else if (key === 'ArrowUp') { event.preventDefault(); move(-1) }
  else if (key === 'Home') { event.preventDefault(); activeIndex.value = nextEnabledIndex(list.value, -1, 1, false); nextTick(scrollActiveIntoView) }
  else if (key === 'End') { event.preventDefault(); activeIndex.value = nextEnabledIndex(list.value, list.value.length, -1, false); nextTick(scrollActiveIntoView) }
  else if (key === 'Enter' || key === ' ') { event.preventDefault(); pick(activeIndex.value) }
  else if (key === 'Tab') close(false)
  else if (key.length === 1) typeahead(key)
}

watch(() => props.disabled, (off) => { if (off) close(false) })
</script>

<template>
  <div
    class="core-selectbox"
    :class="['core-selectbox--' + variant, 'core-selectbox--' + size,
             { 'is-open': open, 'is-invalid': invalid, 'is-disabled': disabled }]"
  >
    <button
      ref="triggerRef"
      type="button"
      class="core-selectbox__trigger"
      role="combobox"
      aria-haspopup="listbox"
      :id="id || undefined"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-controls="open ? listId : undefined"
      :aria-activedescendant="open && activeIndex >= 0 ? listId + '-' + activeIndex : undefined"
      :aria-invalid="invalid ? 'true' : undefined"
      :disabled="disabled"
      @click="open ? close() : openList()"
      @keydown="onKeydown"
    >
      <span v-if="label" class="core-selectbox__caption">{{ label }}</span>
      <span class="core-selectbox__value" :class="{ 'is-placeholder': !selected }">
        <slot name="value" :item="selected">{{ selected ? selected.label : placeholder }}</slot>
      </span>
      <CoreIcon class="core-selectbox__chevron" name="chevron-down" :size="chevronSize" />
    </button>

    <Teleport :to="teleportTo">
      <Transition name="core-pop">
        <div
          v-if="open"
          ref="popupRef"
          :id="listId"
          class="core-selectbox__popup core-scroll"
          :class="'core-selectbox__popup--' + variant"
          role="listbox"
          :style="[popupStyle, popupStyleOwn]"
          @mousedown.prevent
        >
          <div
            v-for="(item, index) in list"
            :key="item.value === undefined ? index : String(item.value)"
            :id="listId + '-' + index"
            class="core-selectbox__option"
            :class="{ 'is-active': index === activeIndex, 'is-selected': index === selectedIndex,
                      'is-disabled': item.disabled }"
            :data-index="index"
            role="option"
            :aria-selected="index === selectedIndex ? 'true' : 'false'"
            :aria-disabled="item.disabled ? 'true' : undefined"
            @click="pick(index)"
            @mousemove="!item.disabled && (activeIndex = index)"
          >
            <slot name="option" :item="item" :selected="index === selectedIndex" :active="index === activeIndex">
              <CoreIcon v-if="item.icon" class="core-selectbox__option-icon" :name="item.icon" size="sm" />
              <span class="core-selectbox__option-body">
                <span class="core-selectbox__option-label">{{ item.label }}</span>
                <span v-if="item.description" class="core-selectbox__option-desc">{{ item.description }}</span>
              </span>
              <CoreIcon v-if="index === selectedIndex" class="core-selectbox__check" name="check" size="xs" />
            </slot>
          </div>
          <p v-if="!list.length" class="core-selectbox__empty">Nothing to choose from.</p>
        </div>
      </Transition>
    </Teleport>
  </div>
</template>
