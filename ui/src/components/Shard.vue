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

const style = computed(() => (STYLES.indexOf(store.shard.style) === -1 ? 'info' : store.shard.style))
</script>

<template>
  <Transition name="shard" mode="out-in">
    <div
      v-if="store.shard.visible"
      :key="store.shard.seq"
      class="shard"
      :class="'is-' + style"
    >
      <div class="band">
        <div class="title">{{ store.shard.title }}</div>
        <div v-if="store.shard.subtitle" class="sub">{{ store.shard.subtitle }}</div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.shard {
  position: fixed;
  z-index: 45;
  left: 0;
  right: 0;
  top: 24vh;
  pointer-events: none;
  text-align: center;
}

/* Full-bleed dark band that fades out towards both screen edges, like the game's. */
.band {
  position: relative;
  padding: 20px 6vw 22px;
  background: linear-gradient(
    90deg,
    rgba(0, 0, 0, 0) 0%,
    rgba(0, 0, 0, 0.74) 20%,
    rgba(0, 0, 0, 0.74) 80%,
    rgba(0, 0, 0, 0) 100%
  );
}

/* Hairlines tinted by the style (no color-mix(): the CEF is on Chrome 103). They fade
   out with the band itself, so neither end draws a hard line across the HUD. */
.band::before,
.band::after {
  content: '';
  position: absolute;
  left: 8%;
  right: 8%;
  height: 1px;
  background: linear-gradient(
    90deg,
    rgba(0, 0, 0, 0) 0%,
    var(--shard) 18%,
    var(--shard) 82%,
    rgba(0, 0, 0, 0) 100%
  );
  opacity: 0.55;
}

.band::before { top: 0; }
.band::after { bottom: 0; }

.is-wasted { --shard: var(--core-error, #ff5d5d); }
.is-success { --shard: var(--core-success, #3ddc84); }
.is-info { --shard: var(--core-accent, #5b8cff); }

.title {
  margin: 0 auto;
  max-width: 86vw;
  color: var(--shard);
  font-size: clamp(34px, 6.2vw, 66px);
  font-weight: 800;
  line-height: 1.05;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  text-shadow: 0 2px 20px rgba(0, 0, 0, 0.7);
  overflow-wrap: anywhere;
}

.sub {
  margin: 8px auto 0;
  max-width: 72vw;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
  font-size: clamp(11px, 1.2vw, 15px);
  font-weight: 600;
  letter-spacing: 0.22em;
  text-transform: uppercase;
  text-shadow: 0 1px 10px rgba(0, 0, 0, 0.8);
  overflow-wrap: anywhere;
}

.shard-enter-active { transition: opacity 0.16s ease, transform 0.3s var(--core-ease, cubic-bezier(0.22, 0.61, 0.36, 1)); }
.shard-leave-active { transition: opacity 0.22s ease, transform 0.22s ease; }

.shard-enter-from { opacity: 0; transform: scale(1.08); }
.shard-leave-to { opacity: 0; transform: scale(0.99); }
</style>
