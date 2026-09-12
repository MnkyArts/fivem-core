<script setup>
// Instructional buttons, bottom right (DESIGN §21 `keys:show { items } ` / `keys:hide`).
// One row of [KEY] label pairs — the shell's take on GTA's instructional-button scaleform.
// Output only: the keys themselves are bound in Lua (`Core.Keys`), this just shows them.
import { store } from '../store.js'
</script>

<template>
  <Transition name="keys">
    <div
      v-if="store.keys.visible && store.keys.items.length"
      class="keys fixed z-[28] right-[18px] bottom-[18px] flex flex-wrap items-center justify-end
             gap-x-[14px] gap-y-[6px] max-w-[64vw] px-[12px] py-[6px]
             bg-panel border border-border rounded-full pointer-events-none"
      data-core-blur
    >
      <span
        v-for="(item, i) in store.keys.items"
        :key="item.key + '|' + item.label + '|' + i"
        class="hint inline-flex items-center gap-[7px] whitespace-nowrap"
      >
        <span
          class="cap min-w-[20px] px-[5px] py-px border border-border-strong rounded-[4px]
                 bg-[rgba(255,255,255,0.08)] text-fg font-mono text-[11px] font-bold
                 leading-[1.45] text-center uppercase"
        >{{ item.key }}</span>
        <span v-if="item.label" class="label text-fg-dim text-ui-sm leading-[1.2]">{{ item.label }}</span>
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
