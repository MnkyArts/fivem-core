<script setup>
// Instructional buttons, bottom right (DESIGN §21 `keys:show { items } ` / `keys:hide`).
// One row of [KEY] label pairs — the shell's take on GTA's instructional-button scaleform.
// Output only: the keys themselves are bound in Lua (`Core.Keys`), this just shows them.
import { store } from '../store.js'
</script>

<template>
  <Transition name="keys">
    <div v-if="store.keys.visible && store.keys.items.length" class="keys">
      <span
        v-for="(item, i) in store.keys.items"
        :key="item.key + '|' + item.label + '|' + i"
        class="hint"
      >
        <span class="cap">{{ item.key }}</span>
        <span v-if="item.label" class="label">{{ item.label }}</span>
      </span>
    </div>
  </Transition>
</template>

<style scoped>
.keys {
  position: fixed;
  z-index: 28;
  right: 18px;
  bottom: 18px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 6px 14px;
  max-width: 64vw;
  padding: 6px 12px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: 999px;
  pointer-events: none;
}

.hint {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  white-space: nowrap;
}

.cap {
  min-width: 20px;
  padding: 1px 5px;
  border: 1px solid var(--core-border-strong, rgba(255, 255, 255, 0.16));
  border-radius: 4px;
  background: rgba(255, 255, 255, 0.08);
  color: var(--core-text, #f2f4f8);
  font-family: var(--core-mono, monospace);
  font-size: 11px;
  font-weight: 700;
  line-height: 1.45;
  text-align: center;
  text-transform: uppercase;
}

.label {
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
  font-size: 12px;
  line-height: 1.2;
}

.keys-enter-active,
.keys-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.keys-enter-from,
.keys-leave-to { opacity: 0; transform: translateY(6px); }
</style>
