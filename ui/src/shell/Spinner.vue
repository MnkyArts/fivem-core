<script setup>
// Bottom-right busy spinner (DESIGN §21 `spinner:show` / `spinner:hide`, §37.6) — the GTA
// "loading prompt": text first, ring on the right. Output only, no callback; it stays
// up until Lua sends `spinner:hide`, so every caller needs a matching hide.
// A kit CoreSpinner on a kit HUD panel. `flex-row-reverse` is what puts the ring on the RIGHT:
// CoreSpinner draws ring-then-label, the game draws label-then-ring.
import { store } from '../store.js'
import CorePanel from '../kit/components/CorePanel.vue'
import CoreSpinner from '../kit/components/CoreSpinner.vue'
</script>

<template>
  <Transition name="spin">
    <!-- z-28 keeps it under TextUI / progress (30); bottom-70px sits it directly above the
         instructional buttons (18 px inset + the kit hint bar's height), exactly like the game's. -->
    <CorePanel
      v-if="store.spinner.visible"
      tag="div"
      variant="hud"
      padding="sm"
      blur
      class="spinner fixed right-[18px] bottom-[70px] z-28 max-w-[42vw] overflow-hidden pointer-events-none"
    >
      <CoreSpinner
        class="flex-row-reverse"
        tone="accent"
        :size="16"
        :label="store.spinner.text"
      />
    </CorePanel>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.spin-enter-active,
.spin-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.spin-enter-from,
.spin-leave-to { opacity: 0; transform: translateY(4px); }
</style>
