<script setup>
// Bottom-right busy spinner (DESIGN §21 `spinner:show` / `spinner:hide`) — the GTA
// "loading prompt": text first, ring on the right. Output only, no callback; it stays
// up until Lua sends `spinner:hide`, so every caller needs a matching hide.
import { store } from '../store.js'
</script>

<template>
  <Transition name="spin">
    <!-- z-28 keeps it under TextUI / progress (30); bottom-62px sits it directly above the
         instructional buttons, exactly like the game's. -->
    <div
      v-if="store.spinner.visible"
      class="spinner pointer-events-none fixed right-[18px] bottom-[62px] z-28 flex max-w-[42vw] items-center gap-2.5 rounded-[999px] border border-border bg-panel py-1.5 pr-2 pl-[13px]"
    >
      <span v-if="store.spinner.text" class="text truncate text-[13px] leading-[1.2] text-fg">{{ store.spinner.text }}</span>
      <span class="ring size-4 flex-none rounded-[50%] border-2 border-border-strong border-t-accent"></span>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue hashes keyframes declared in a scoped block and rewrites only the `animation`
   declarations next to them, so the ring's binding has to stay here — a utility would
   reference the unhashed name. Same for the transition classes Vue toggles itself. */
.ring { animation: spinner-turn 0.75s linear infinite; }

@keyframes spinner-turn {
  to { transform: rotate(360deg); }
}

.spin-enter-active,
.spin-leave-active { transition: opacity 0.15s ease, transform 0.18s ease; }

.spin-enter-from,
.spin-leave-to { opacity: 0; transform: translateY(4px); }
</style>
