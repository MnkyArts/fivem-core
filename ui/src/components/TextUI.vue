<script setup>
// Text UI pill, bottom centre by default: [E] Open shop (DESIGN §7.2).
import { computed } from 'vue'
import { store } from '../store.js'

const POSITIONS = ['bottom', 'top', 'left', 'right']

// Placement utilities per position. `.pos-*` stays on the element as a hook class.
const PLACEMENT = {
  bottom: 'left-0 right-0 bottom-[14vh] w-max mx-auto justify-center',
  top: 'left-0 right-0 top-[12vh] w-max mx-auto justify-center',
  left: 'left-[24px] top-1/2 -translate-y-1/2',
  right: 'right-[24px] top-1/2 -translate-y-1/2',
}

const pos = computed(() => {
  const p = store.textui.position
  return POSITIONS.indexOf(p) === -1 ? 'bottom' : p
})
</script>

<template>
  <Transition name="tui">
    <div
      v-if="store.textui.visible"
      class="textui fixed z-30 flex items-center gap-[9px] max-w-[42vw] py-[7px] pr-[13px] pl-[8px]
             bg-panel border border-border rounded-full text-fg text-ui leading-[1.2]
             pointer-events-none whitespace-nowrap"
      :class="['pos-' + pos, PLACEMENT[pos]]"
      data-core-blur
    >
      <span
        v-if="store.textui.key"
        class="key flex-none min-w-[22px] px-[6px] py-[2px] border border-accent rounded-ui-sm
               bg-[rgba(91,140,255,0.12)] text-accent text-ui-sm font-bold text-center uppercase"
      >{{ store.textui.key }}</span>
      <span class="text overflow-hidden text-ellipsis">{{ store.textui.text }}</span>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.tui-enter-active,
.tui-leave-active { transition: opacity 0.15s ease; }

.tui-enter-from,
.tui-leave-to { opacity: 0; }
</style>
