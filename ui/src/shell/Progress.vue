<script setup>
// Bottom-centre progress bar (DESIGN §6.10 progress:start/stop, §37.6).
// The fill is a plain CSS width transition seeded from store.progress.startedAt, so a
// late mount still shows the right offset. store.js owns the completion timer
// (progress:start -> progressDone) and the x / Backspace cancel keys (handleKeydown).
// The bar is a kit CoreProgress on a kit HUD panel; the seeded transition reaches the fill
// element through CoreProgress's `fillEl` expose (§37.5) — `value` stays 0 and is never patched
// again, so nothing of the kit's fights the imperative width.
import { ref, watch, onMounted, nextTick } from 'vue'
import { store } from '../store.js'
import CorePanel from '../kit/components/CorePanel.vue'
import CoreProgress from '../kit/components/CoreProgress.vue'
import CoreKeyHint from '../kit/components/CoreKeyHint.vue'

const bar = ref(null)

async function paint () {
  const p = store.progress
  if (!p.visible) return

  const id = p.id
  const duration = Math.max(0, Number(p.duration) || 0)
  const started = Number(p.startedAt) || Date.now()

  await nextTick()
  const el = bar.value && bar.value.fillEl
  if (!el || !store.progress.visible || store.progress.id !== id) return

  const elapsed = Math.max(0, Date.now() - started)
  const remaining = Math.max(0, duration - elapsed)
  const pct = duration > 0 ? Math.min(100, (elapsed / duration) * 100) : 100

  el.style.transition = 'none'
  el.style.width = pct + '%'
  void el.offsetWidth // force a reflow so the next width animates from here
  el.style.transition = 'width ' + remaining + 'ms linear'
  el.style.width = '100%'
}

watch(() => [store.progress.visible, store.progress.id, store.progress.startedAt], paint)

onMounted(paint)
</script>

<template>
  <Transition name="prog">
    <CorePanel
      v-if="store.progress.visible"
      variant="hud"
      padding="sm"
      blur
      class="progress fixed z-30 left-1/2 bottom-[7vh] w-[340px] -ml-[170px] pointer-events-none"
    >
      <!-- The label is CoreProgress's own caption and the cancel hint takes the read-out slot, so
           the head row (caption left, value right) is the kit's, not the shell's. -->
      <CoreProgress ref="bar" class="track" size="md" tone="accent" :label="store.progress.label">
        <template #value>
          <CoreKeyHint v-if="store.progress.canCancel" class="hint" keys="X" label="to cancel" size="sm" />
        </template>
      </CoreProgress>
    </CorePanel>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.prog-enter-active,
.prog-leave-active { transition: opacity 0.15s ease; }

.prog-enter-from,
.prog-leave-to { opacity: 0; }
</style>
