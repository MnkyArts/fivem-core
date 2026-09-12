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
    <div v-if="visible" class="core-backdrop menu-back">
      <div class="core-panel core-modal menu">
        <h2 class="core-title">{{ store.menu.title || 'Menu' }}</h2>
        <ul ref="listEl" class="core-list" role="menu">
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
            <span v-if="item.icon" class="icon">{{ item.icon }}</span>
            <span class="body">
              <span class="label">{{ item.label }}</span>
              <span v-if="item.description" class="desc">{{ item.description }}</span>
            </span>
          </li>
          <li v-if="!items.length" class="core-item is-disabled">No entries</li>
        </ul>
        <p class="hint">&#8593;&#8595; move &middot; <b>Enter</b> select &middot; <b>Esc</b> close</p>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.menu-back { z-index: 50; }

.menu {
  width: 380px;
  max-width: 80vw;
  padding-bottom: 6px;
  animation: core-pop-in 0.12s var(--core-ease, ease);
}

.core-list { margin-top: 8px; }

.icon {
  flex: 0 0 auto;
  min-width: 20px;
  text-align: center;
  font-size: 13px;
  color: var(--core-accent, #5b8cff);
}

.body {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.label {
  font-size: var(--core-fs-sm, 12px);
  line-height: 1.3;
}

.desc {
  font-size: var(--core-fs-xs, 10px);
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

.hint {
  margin: 8px 0 0;
  padding-top: 8px;
  border-top: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  font-size: var(--core-fs-xs, 10px);
  color: var(--core-text-faint, rgba(242, 244, 248, 0.38));
}

.hint b { color: var(--core-text-dim, rgba(242, 244, 248, 0.62)); font-weight: 600; }

.menu-enter-active,
.menu-leave-active { transition: opacity 0.12s ease; }

.menu-enter-from,
.menu-leave-to { opacity: 0; }
</style>
