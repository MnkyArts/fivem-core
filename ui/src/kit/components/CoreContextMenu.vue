<script setup>
// CoreContextMenu — right-click menu (DESIGN §37.5, Feedback).
// There is no anchor element to measure, so it is placed with placeFloating() against a ZERO-SIZE
// rect at `position`: the same flip-then-clamp maths every kit popup uses, which is what keeps a
// menu opened in the bottom-right corner fully on screen. The panel takes focus on open (arrows
// have to reach it however the menu was summoned) and separators navigate like disabled rows.
import { computed, nextTick, onMounted, onScopeDispose, ref, watch } from 'vue'
import {
  normalizeItems, nextEnabledIndex, onClickOutside, overlayTarget, placeFloating, useEscapeLayer,
} from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** `v-model:open`. */
  open: { type: Boolean, default: false },
  /** Where the menu's top-left corner wants to be, in viewport px. */
  position: { type: Object, default: () => ({ x: 0, y: 0 }) },
  /** `{ value, label, icon?, kbd?, danger?, disabled?, separator? }` — strings work too. */
  items: { type: Array, default: () => [] },
})

const emit = defineEmits(['select', 'update:open'])

const panelRef = ref(null)
const openRef = ref(props.open)
const activeIndex = ref(-1)
const style = ref({ position: 'fixed', left: '0px', top: '0px' })

const rows = computed(() => normalizeItems(props.items))
/** Roving skips separators exactly like disabled rows, so nextEnabledIndex needs them flagged. */
const navRows = computed(() => rows.value.map((row) => (row.separator ? { disabled: true } : row)))

watch(() => props.open, (value) => { openRef.value = value })

function setOpen (value) {
  if (openRef.value === value) return
  openRef.value = value
  emit('update:open', value)
}

function place () {
  const panel = panelRef.value
  if (!panel || typeof window === 'undefined') return
  const at = props.position || {}
  const placed = placeFloating(
    { left: Number(at.x) || 0, top: Number(at.y) || 0, width: 0, height: 0 },
    { width: panel.offsetWidth, height: panel.offsetHeight },
    { placement: 'bottom-start', offset: 0, padding: 8 },
  )
  style.value = { position: 'fixed', left: Math.round(placed.x) + 'px', top: Math.round(placed.y) + 'px' }
}

function choose (index) {
  const row = rows.value[index]
  if (!row || row.separator || row.disabled) return
  emit('select', row)
  setOpen(false)
}

function move (dir) {
  activeIndex.value = nextEnabledIndex(navRows.value, activeIndex.value, dir, true)
}

function onKeydown (event) {
  if (event.key === 'ArrowDown') { event.preventDefault(); move(1) }
  else if (event.key === 'ArrowUp') { event.preventDefault(); move(-1) }
  else if (event.key === 'Home') { event.preventDefault(); activeIndex.value = nextEnabledIndex(navRows.value, -1, 1, false) }
  else if (event.key === 'End') { event.preventDefault(); activeIndex.value = nextEnabledIndex(navRows.value, rows.value.length, -1, false) }
  else if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); choose(activeIndex.value) }
}

const dismiss = () => setOpen(false)

function listen (on) {
  if (typeof window === 'undefined') return
  const fn = on ? window.addEventListener : window.removeEventListener
  fn.call(window, 'blur', dismiss)
  fn.call(window, 'scroll', dismiss, true)
  fn.call(window, 'resize', dismiss)
}

watch(openRef, (value) => {
  listen(false)
  if (!value) return
  activeIndex.value = -1
  nextTick(() => {
    place()
    listen(true)
    if (panelRef.value) panelRef.value.focus()
  })
}, { immediate: true })

watch(() => props.position, () => { if (openRef.value) nextTick(place) }, { deep: true })

// The Teleport target, resolved as early as it can honestly be. `#core-overlays` is the LAST child
// of `.core-root` (§37.3), so calling overlayTarget() during the first render would CREATE a second
// element with that id — hence a lookup-only read here, with overlayTarget() kept as the mounted
// fallback for the case where the element really was not there yet. Resolving at setup matters for
// a popup that is created already open: swapping the target after mount MOVES the panel, and moving
// a focused node blurs it.
const teleportTo = ref(typeof document === 'undefined' ? 'body' : document.getElementById('core-overlays') || 'body')
onMounted(() => { if (teleportTo.value === 'body') teleportTo.value = overlayTarget() || 'body' })
useEscapeLayer(openRef, dismiss)
onClickOutside(() => [panelRef], dismiss, openRef)
onScopeDispose(() => listen(false))
</script>

<template>
  <Teleport :to="teleportTo">
    <Transition name="core-pop">
      <div
        v-if="openRef"
        ref="panelRef"
        v-bind="$attrs"
        class="core-contextmenu"
        :style="style"
        role="menu"
        tabindex="-1"
        @keydown="onKeydown"
      >
        <template v-for="(row, i) in rows" :key="row.separator ? 'sep-' + i : row.value">
          <div v-if="row.separator" class="core-contextmenu__sep" role="separator"></div>
          <button
            v-else
            type="button"
            tabindex="-1"
            role="menuitem"
            class="core-contextmenu__item"
            :class="{ 'is-active': i === activeIndex, 'is-danger': row.danger, 'is-disabled': row.disabled }"
            :aria-disabled="row.disabled ? 'true' : null"
            @mouseenter="activeIndex = row.disabled ? activeIndex : i"
            @click="choose(i)"
          >
            <slot name="item" :item="row" :active="i === activeIndex">
              <CoreIcon v-if="row.icon" class="core-contextmenu__icon" :name="row.icon" size="sm" />
              <span class="core-contextmenu__label">{{ row.label }}</span>
              <span v-if="row.kbd" class="core-contextmenu__kbd">{{ row.kbd }}</span>
            </slot>
          </button>
        </template>
      </div>
    </Transition>
  </Teleport>
</template>
