<script setup>
// Instructional buttons, bottom right (DESIGN §21 `keys:show { items }` / `keys:hide`, §37.6).
// One row of [KEY] label pairs — the shell's take on GTA's instructional-button scaleform, and
// literally the kit's CoreKeyHints (the map footer of mockup 4). Output only: the keys themselves
// are bound in Lua (`Core.Keys`), this just shows them.
// CoreKeyHints takes the store's `{ key, label }` items as they are (normalizeItems keeps `key`),
// and a mouse name still draws as a glyph because CoreKeyHint hands every cap to CoreKey.
import { store } from '../store.js'
import CoreKeyHints from '../kit/components/CoreKeyHints.vue'
</script>

<template>
  <Transition name="keys">
    <CoreKeyHints
      v-if="store.keys.visible && store.keys.items.length"
      :items="store.keys.items"
      align="end"
      size="md"
      blur
      class="keys fixed z-[28] right-[18px] bottom-[18px] max-w-[64vw] pointer-events-none"
    />
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.keys-enter-active,
.keys-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.keys-enter-from,
.keys-leave-to { opacity: 0; transform: translateY(6px); }
</style>
