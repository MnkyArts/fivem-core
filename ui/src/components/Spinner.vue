<script setup>
// Bottom-right busy spinner (DESIGN §21 `spinner:show` / `spinner:hide`) — the GTA
// "loading prompt": text first, ring on the right. Output only, no callback; it stays
// up until Lua sends `spinner:hide`, so every caller needs a matching hide.
import { store } from '../store.js'
</script>

<template>
  <Transition name="spin">
    <div v-if="store.spinner.visible" class="spinner">
      <span v-if="store.spinner.text" class="text">{{ store.spinner.text }}</span>
      <span class="ring"></span>
    </div>
  </Transition>
</template>

<style scoped>
.spinner {
  position: fixed;
  z-index: 28;
  right: 18px;
  /* sits directly above the instructional buttons, exactly like the game's */
  bottom: 62px;
  display: flex;
  align-items: center;
  gap: 10px;
  max-width: 42vw;
  padding: 6px 8px 6px 13px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: 999px;
  pointer-events: none;
}

.text {
  color: var(--core-text, #f2f4f8);
  font-size: 13px;
  line-height: 1.2;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.ring {
  flex: 0 0 auto;
  width: 16px;
  height: 16px;
  border: 2px solid rgba(255, 255, 255, 0.16);
  border-top-color: var(--core-accent, #5b8cff);
  border-radius: 50%;
  animation: spinner-turn 0.75s linear infinite;
}

@keyframes spinner-turn {
  to { transform: rotate(360deg); }
}

.spin-enter-active,
.spin-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.spin-enter-from,
.spin-leave-to { opacity: 0; transform: translateY(4px); }
</style>
