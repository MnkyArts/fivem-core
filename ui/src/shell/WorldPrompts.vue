<script setup>
// World interaction dots (DESIGN §6.7 `worldprompts:set`, §37.6): one CoreInteractionDot per
// projected interaction. Lua sends the normalized (0..1) screen point ~30×/s while a dot moves
// and the wrapper here carries it as a `transform: translate3d()` — compositor-only, no layout —
// with a 34 ms linear transition so the dot glides between two sends. The dot itself is the kit's
// 0 x 0 anchor, centred on the wrapper origin; the layer is aria-hidden and click-through: a dot
// is painted, never clicked (§37.4).
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { store } from '../store.js'

// Viewport px are not reactive, so the placed dots recompute through this ref; kit/use.js's
// own viewport listener is the pattern. Cleaned up on unmount.
const viewport = ref({ w: window.innerWidth, h: window.innerHeight })
const onResize = () => { viewport.value = { w: window.innerWidth, h: window.innerHeight } }
onMounted(() => window.addEventListener('resize', onResize))
onBeforeUnmount(() => window.removeEventListener('resize', onResize))

function placed (item) {
  const w = viewport.value.w || 1
  const h = viewport.value.h || 1
  return { transform: 'translate3d(' + (item.x * w) + 'px,' + (item.y * h) + 'px,0)' }
}

// Near the right edge the band opens leftwards so it never runs off screen.
function sideOf (item) {
  return item.x > 0.6 ? 'left' : 'right'
}
</script>

<template>
  <div aria-hidden="true" class="fixed inset-0 z-20 overflow-hidden pointer-events-none">
    <div v-for="item in store.worldprompts.items" :key="item.id" class="wp-dot" :style="placed(item)">
      <CoreInteractionDot
        :side="sideOf(item)"
        :focused="item.focused"
        :disabled="item.disabled"
        :keys="item.keys"
        :label="item.label"
        :icon="item.icon"
        :description="item.description"
      />
    </div>
  </div>
</template>

<style scoped>
/* Position lives on the compositor; 34 ms linear matches Lua's ~30 Hz `worldprompts:set`
   cadence, so a moving dot is interpolated instead of stepping. The kit dot is the visual. */
.wp-dot {
  position: absolute;
  left: 0;
  top: 0;
  transition: transform 34ms linear;
}
</style>
