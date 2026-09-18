<script setup>
// Text UI prompt, bottom centre by default: [E] OPEN SHOP (DESIGN §6.10, §37.6).
// Wears the kit's CorePrompt look (kit/css/actions.css) with the shell's own markup, so the
// `.textui` / `.key` / `.text` / `.pos-*` hooks stay where they are and the glass (§32.1) can sit
// on the BAND alone — a blurred rectangle behind the whole prompt would put back the box the
// mockup's dissolving plate is there to avoid.
import { computed } from 'vue'
import { store } from '../store.js'
import CoreKey from '../kit/components/CoreKey.vue'

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
    <div
      v-if="store.textui.visible"
      class="textui core-prompt fixed z-30 max-w-[42vw]"
      :class="['pos-' + pos, PLACEMENT[pos]]"
    >
      <span v-if="store.textui.key" class="core-prompt__keys">
        <CoreKey class="key" :label="store.textui.key" size="lg" />
      </span>
      <span class="band core-prompt__band" data-core-blur>
        <span class="core-prompt__text">
          <span class="text core-prompt__label truncate">{{ store.textui.text }}</span>
        </span>
      </span>
    </div>
  </Transition>
</template>

<style scoped>
/* The plate and its blurred copy of the game have to dissolve together, so the band carries a FLAT
   fill plus one mask instead of the kit's gradient background: a gradient only fades the fill and
   would leave the `.core-glass` canvas as a hard-edged rectangle over the world (§32.1).
   Chromium 103 only knows the prefixed longhand.
   The tail is a fixed 76 px rather than the kit's percentage, because a shell prompt carries
   whatever Lua sends: with a percentage, a long line would start dissolving mid-sentence. The same
   76 px of right padding keeps the text out of it, so the plate always fades on empty space. */
.band {
  padding-right: 76px;
  background: rgb(var(--core-ink-rgb) / 0.78);
  -webkit-mask-image: linear-gradient(90deg, #000 0, #000 calc(100% - 76px), transparent 100%);
}

/* Vue transition classes — not expressible as utilities. */
.tui-enter-active,
.tui-leave-active { transition: opacity 0.15s ease; }

.tui-enter-from,
.tui-leave-to { opacity: 0; }
</style>
