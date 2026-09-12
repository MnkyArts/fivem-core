<script setup>
// Text UI pill, bottom centre by default: [E] Open shop (DESIGN §7.2).
import { computed } from 'vue'
import { store } from '../store.js'

const POSITIONS = ['bottom', 'top', 'left', 'right']

const pos = computed(() => {
  const p = store.textui.position
  return POSITIONS.indexOf(p) === -1 ? 'bottom' : p
})
</script>

<template>
  <Transition name="tui">
    <div v-if="store.textui.visible" class="textui" :class="'pos-' + pos">
      <span v-if="store.textui.key" class="key">{{ store.textui.key }}</span>
      <span class="text">{{ store.textui.text }}</span>
    </div>
  </Transition>
</template>

<style scoped>
.textui {
  position: fixed;
  z-index: 30;
  display: flex;
  align-items: center;
  gap: 9px;
  max-width: 42vw;
  padding: 7px 13px 7px 8px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: 999px;
  color: var(--core-text, #f2f4f8);
  font-size: 14px;
  line-height: 1.2;
  pointer-events: none;
  white-space: nowrap;
}

.pos-bottom {
  left: 0;
  right: 0;
  bottom: 14vh;
  width: max-content;
  margin-inline: auto;
  justify-content: center;
}

.pos-top {
  left: 0;
  right: 0;
  top: 12vh;
  width: max-content;
  margin-inline: auto;
  justify-content: center;
}

.pos-left { left: 24px; top: 50%; transform: translateY(-50%); }
.pos-right { right: 24px; top: 50%; transform: translateY(-50%); }

.key {
  flex: 0 0 auto;
  min-width: 22px;
  padding: 2px 6px;
  border: 1px solid var(--core-accent, #5b8cff);
  border-radius: 5px;
  background: rgba(91, 140, 255, 0.12);
  color: var(--core-accent, #5b8cff);
  font-size: 12px;
  font-weight: 700;
  text-align: center;
  text-transform: uppercase;
}

.text {
  overflow: hidden;
  text-overflow: ellipsis;
}

.tui-enter-active,
.tui-leave-active { transition: opacity 0.15s ease; }

.tui-enter-from,
.tui-leave-to { opacity: 0; }
</style>
