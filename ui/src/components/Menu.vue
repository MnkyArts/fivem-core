<script setup>
// Centred keyboard menu (DESIGN §6.10 `menu:open`, §7.2, §7.3).
// store.js owns Escape (-> menuResult(null)); this component owns Up/Down/Enter and the mouse.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, menuResult, activeModal } from '../store.js'
// Imported by path, not by the kit's global registration: the shell must not depend on install
// order (DESIGN §37.6). CoreKeyHints draws the footer row of caps.
import CoreKeyHints from '../kit/components/CoreKeyHints.vue'

// The three keys this component and store.js answer to, in the footer's reading order.
const HINTS = [
  { keys: ['↑', '↓'], label: 'Move' },
  { key: 'Enter', label: 'Select' },
  { key: 'Esc', label: 'Close' },
]

const listEl = ref(null)
const selected = ref(0)
const visible = computed(() => store.menu.visible)
const items = computed(() => (Array.isArray(store.menu.items) ? store.menu.items : []))

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
    const el = listEl.value && listEl.value.querySelector('[data-index="' + i + '"]')
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest' })
  })
}

function hover (i) {
  if (usable(i)) select(i)
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
  <Transition name="menu">
    <div v-if="visible" class="core-backdrop menu-back z-50">
      <div
        class="core-dialog core-tone-accent core-dialog--md menu animate-[core-pop-in_0.12s_var(--ease-ui)]"
        data-core-blur
      >
        <div class="core-dialog__header">
          <div class="core-dialog__titles">
            <h2 class="core-title core-dialog__title">{{ store.menu.title || 'Menu' }}</h2>
          </div>
        </div>
        <!-- The rows are full-bleed inside the panel, so the body drops the dialog's side padding
             and the row's own `px-5` re-aligns the labels with the title above. -->
        <ul ref="listEl" class="core-list core-menu--sm core-dialog__body core-scroll px-0 pt-0 pb-1.5" role="menu">
          <li
            v-for="(item, i) in items"
            :key="i"
            class="core-item core-menu__item min-h-11 gap-4 px-5"
            :class="{ 'is-active': i === selected, 'is-disabled': !!item.disabled }"
            role="menuitem"
            :data-index="i"
            :aria-selected="i === selected"
            :aria-disabled="!!item.disabled"
            @mouseenter="hover(i)"
            @click="choose(i)"
          >
            <span v-if="item.icon" class="icon core-menu__icon text-[15px] text-accent">{{ item.icon }}</span>
            <span class="body core-menu__body">
              <span class="label core-menu__label">{{ item.label }}</span>
              <span v-if="item.description" class="desc core-menu__desc">{{ item.description }}</span>
            </span>
          </li>
          <li v-if="!items.length" class="core-item core-menu__item is-disabled min-h-11 px-5">
            <span class="label core-menu__label">No entries</span>
          </li>
        </ul>
        <div class="core-dialog__footer">
          <CoreKeyHints class="hint" :items="HINTS" align="end" size="sm" bare />
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Only what Vue toggles itself; everything static lives in the template's utilities. */
.menu-enter-active,
.menu-leave-active { transition: opacity 0.12s ease; }

.menu-enter-from,
.menu-leave-to { opacity: 0; }
</style>
