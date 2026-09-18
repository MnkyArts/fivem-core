<script setup>
// Text UI prompt, bottom centre by default: [E] OPEN SHOP (DESIGN §6.10, §37.6).
// The widget IS the kit's CorePrompt (cap + dissolving band): the shell only decides WHERE it
// sits, so `.textui` and `.pos-*` ride along on the component's root and every part of the look
// comes from kit/css/actions.css.
import { computed } from 'vue'
import { store } from '../store.js'
import CorePrompt from '../kit/components/CorePrompt.vue'

const POSITIONS = ['bottom', 'top', 'left', 'right']

// Placement utilities per position. `.pos-*` stays on the element as a hook class.
const PLACEMENT = {
  bottom: 'left-0 right-0 bottom-[14vh] w-max mx-auto justify-center',
  top: 'left-0 right-0 top-[12vh] w-max mx-auto justify-center',
  left: 'left-[24px] top-1/2 [transform:translateY(-50%)]',
  right: 'right-[24px] top-1/2 [transform:translateY(-50%)]',
}

const pos = computed(() => {
  const p = store.textui.position
  return POSITIONS.indexOf(p) === -1 ? 'bottom' : p
})
</script>

<template>
  <Transition name="tui">
    <!-- The prompt is click-through by itself (`.core-prompt` sets pointer-events: none), so the
         placement utilities are all the shell adds. `block truncate` inside the label keeps the
         documented one-line behaviour: the band shrinks with `.core-prompt__text`'s min-width 0. -->
    <CorePrompt
      v-if="store.textui.visible"
      class="textui fixed z-30 max-w-[42vw]"
      :class="['pos-' + pos, PLACEMENT[pos]]"
      :keys="store.textui.key"
    >
      <span class="block truncate">{{ store.textui.text }}</span>
    </CorePrompt>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.tui-enter-active,
.tui-leave-active { transition: opacity 0.15s ease; }

.tui-enter-from,
.tui-leave-to { opacity: 0; }
</style>
