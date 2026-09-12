<script setup>
// Centred keyboard menu (DESIGN §6.10 `menu:open`, §7.2, §7.3).
// store.js owns Escape (-> menuResult(null)); this component owns Up/Down/Enter and the mouse.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, menuResult, activeModal } from '../store.js'

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
      <div class="core-panel core-modal menu w-[380px] max-w-[80vw] pb-1.5 animate-[core-pop-in_0.12s_var(--ease-ui)]" data-core-blur>
        <h2 class="core-title">{{ store.menu.title || 'Menu' }}</h2>
        <ul ref="listEl" class="core-list mt-2" role="menu">
          <li
            v-for="(item, i) in items"
            :key="i"
            class="core-item"
            :class="{ 'is-active': i === selected, 'is-disabled': !!item.disabled }"
            role="menuitem"
            :data-index="i"
            :aria-selected="i === selected"
            :aria-disabled="!!item.disabled"
            @mouseenter="hover(i)"
            @click="choose(i)"
          >
            <span v-if="item.icon" class="icon min-w-5 flex-none text-center text-[13px] text-accent">{{ item.icon }}</span>
            <span class="body flex min-w-0 flex-col">
              <span class="label text-ui-sm leading-[1.3]">{{ item.label }}</span>
              <span v-if="item.description" class="desc text-ui-xs text-fg-dim">{{ item.description }}</span>
            </span>
          </li>
          <li v-if="!items.length" class="core-item is-disabled">No entries</li>
        </ul>
        <!-- one line on purpose: Vue's whitespace: 'condense' would eat the spaces around the <b>s -->
        <p class="hint mt-2 border-t border-t-border pt-2 text-ui-xs text-fg-faint [&_b]:font-semibold [&_b]:text-fg-dim">&#8593;&#8595; move &middot; <b>Enter</b> select &middot; <b>Esc</b> close</p>
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
