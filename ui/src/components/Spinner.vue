<script setup>
// Bottom-right busy spinner (DESIGN §21 `spinner:show` / `spinner:hide`, §37.6) — the GTA
// "loading prompt": text first, ring on the right. Output only, no callback; it stays
// up until Lua sends `spinner:hide`, so every caller needs a matching hide.
// Kit look: the `core-spinner` classes on a HUD chip (4 px radius, hairline, `--color-hud`).
import { store } from '../store.js'
</script>

<template>
  <Transition name="spin">
    <!-- z-28 keeps it under TextUI / progress (30); bottom-70px sits it directly above the
         instructional buttons (18 px inset + the kit hint bar's 44 px), exactly like the game's. -->
    <div
      v-if="store.spinner.visible"
      class="spinner core-spinner core-tone-accent pointer-events-none fixed right-[18px] bottom-[70px] z-28
             max-w-[42vw] rounded-ui-sm border border-border bg-hud py-[7px] pr-[11px] pl-[13px]"
      data-core-blur
    >
      <span v-if="store.spinner.text" class="text core-spinner__label truncate text-fg">{{ store.spinner.text }}</span>
      <!-- The kit's ring reads its stroke from `--core-spinner-w` (2 px default) and its lit side
           from `--tone`, which `core-tone-accent` above sets to the brand coral. -->
      <span class="ring core-spinner__ring" style="width: 16px; height: 16px"></span>
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
