<script setup>
// Centre-screen shard banner (DESIGN §21 `shard:show`) — GTA's "WASTED" / "MISSION
// PASSED" card. Output only: store.js owns the auto-hide timer (`duration`, 4 s by
// default) and nothing is ever posted back to Lua.
//
// `store.shard.seq` keys the inner element, so a second shard arriving while the first
// is still up replays the animation instead of silently swapping the text.
import { computed } from 'vue'
import { store } from '../store.js'

const STYLES = ['wasted', 'success', 'info']

// The style sets one custom property, `--shard`, which tints the title and the band's two
// hairlines. The `is-*` class stays next to it: it carries no rules any more but it is the
// hook the stories assert on (and it reads in the DOM inspector).
const TINT = {
  wasted: '[--shard:var(--color-error)]',
  success: '[--shard:var(--color-success)]',
  info: '[--shard:var(--color-accent)]',
}

const style = computed(() => (STYLES.indexOf(store.shard.style) === -1 ? 'info' : store.shard.style))
</script>

<template>
  <Transition name="shard" mode="out-in">
    <div
      v-if="store.shard.visible"
      :key="store.shard.seq"
      class="shard pointer-events-none fixed inset-x-0 top-[24vh] z-45 text-center"
      :class="['is-' + style, TINT[style]]"
    >
      <!-- Full-bleed dark band that fades out towards both screen edges, like the game's, with a
           hairline top and bottom tinted by the style (no color-mix(): the CEF is on Chrome 103).
           The hairlines fade with the band, so neither end draws a hard line across the HUD. -->
      <div
        class="band relative px-[6vw] pt-5 pb-[22px] bg-[linear-gradient(90deg,transparent_0%,rgba(0,0,0,0.74)_20%,rgba(0,0,0,0.74)_80%,transparent_100%)]
               before:absolute before:inset-x-[8%] before:top-0 before:h-px before:opacity-[0.55] before:content-['']
               before:bg-[linear-gradient(90deg,transparent_0%,var(--shard)_18%,var(--shard)_82%,transparent_100%)]
               after:absolute after:inset-x-[8%] after:bottom-0 after:h-px after:opacity-[0.55] after:content-['']
               after:bg-[linear-gradient(90deg,transparent_0%,var(--shard)_18%,var(--shard)_82%,transparent_100%)]"
      >
        <div class="title mx-auto max-w-[86vw] text-[clamp(34px,6.2vw,66px)] leading-[1.05] font-extrabold tracking-[0.06em] text-[color:var(--shard)] uppercase [text-shadow:0_2px_20px_rgba(0,0,0,0.7)] [overflow-wrap:anywhere]">{{ store.shard.title }}</div>
        <div v-if="store.shard.subtitle" class="sub mx-auto mt-2 max-w-[72vw] text-[clamp(11px,1.2vw,15px)] font-semibold tracking-[0.22em] text-fg-dim uppercase [text-shadow:0_1px_10px_rgba(0,0,0,0.8)] [overflow-wrap:anywhere]">{{ store.shard.subtitle }}</div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Only what Vue toggles itself; everything static lives in the template's utilities. */
.shard-enter-active { transition: opacity 0.16s ease, transform 0.3s var(--ease-ui, cubic-bezier(0.22, 0.61, 0.36, 1)); }
.shard-leave-active { transition: opacity 0.22s ease, transform 0.22s ease; }

.shard-enter-from { opacity: 0; transform: scale(1.08); }
.shard-leave-to { opacity: 0; transform: scale(0.99); }
</style>
