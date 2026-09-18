<script setup>
// Instructional buttons, bottom right (DESIGN §21 `keys:show { items }` / `keys:hide`, §37.6).
// One row of [KEY] label pairs — the shell's take on GTA's instructional-button scaleform, wearing
// the kit's hint-bar look (the map footer of mockup 4). Output only: the keys themselves are bound
// in Lua (`Core.Keys`), this just shows them.
// The row is written with the kit's CLASSES around a real <CoreKey> (which draws a mouse name as a
// glyph) so `.hint`, `.cap` and `.label` keep meaning exactly what they meant before.
import { store } from '../store.js'
import CoreKey from '../kit/components/CoreKey.vue'
</script>

<template>
  <Transition name="keys">
    <div
      v-if="store.keys.visible && store.keys.items.length"
      class="keys core-keyhints core-keyhints--end fixed z-[28] right-[18px] bottom-[18px]
             max-w-[64vw] pointer-events-none"
      data-core-blur
    >
      <span
        v-for="(item, i) in store.keys.items"
        :key="item.key + '|' + item.label + '|' + i"
        class="hint core-keyhint core-keyhint--md"
      >
        <span class="core-keyhint__keys">
          <CoreKey class="cap" :label="item.key" size="md" />
        </span>
        <span v-if="item.label" class="label core-keyhint__label">{{ item.label }}</span>
      </span>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.keys-enter-active,
.keys-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.keys-enter-from,
.keys-leave-to { opacity: 0; transform: translateY(6px); }
</style>
