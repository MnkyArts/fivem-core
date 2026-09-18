<script setup>
// Bottom-centre progress bar (DESIGN §6.10 progress:start/stop, §37.6).
// The fill is a plain CSS width transition seeded from store.progress.startedAt, so a
// late mount still shows the right offset. store.js owns the completion timer
// (progress:start -> progressDone) and the x / Backspace cancel keys (handleKeydown).
// The bar wears the kit's CoreProgress CLASSES rather than the component: `fillEl` has to be a
// real ref on the fill element, and rendering <CoreProgress> would hide it behind the child.
import { ref, watch, onMounted, nextTick } from 'vue'
import { store } from '../store.js'
import CoreKeyHint from '../kit/components/CoreKeyHint.vue'

const fillEl = ref(null)

async function paint () {
  const p = store.progress
  if (!p.visible) return

  const id = p.id
  const duration = Math.max(0, Number(p.duration) || 0)
  const started = Number(p.startedAt) || Date.now()

  await nextTick()
  const el = fillEl.value
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
    <div
      v-if="store.progress.visible"
      class="progress fixed z-30 left-1/2 bottom-[7vh] w-[340px] -ml-[170px]
             pt-[11px] px-[14px] pb-[13px]
             bg-panel border border-border rounded-ui-sm shadow-ui pointer-events-none"
      data-core-blur
    >
      <div class="head flex items-center justify-between gap-[12px] mb-[9px]">
        <span
          class="label min-w-0 truncate font-display text-ui-sm font-semibold uppercase
                 tracking-label leading-[1.3] text-fg"
        >{{ store.progress.label }}</span>
        <CoreKeyHint v-if="store.progress.canCancel" class="hint flex-none" keys="X" label="to cancel" size="sm" />
      </div>
      <div class="core-progress core-progress--md core-tone-accent">
        <div class="track core-progress__track">
          <div ref="fillEl" class="fill core-progress__fill"></div>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Vue transition classes — not expressible as utilities. */
.prog-enter-active,
.prog-leave-active { transition: opacity 0.15s ease; }

.prog-enter-from,
.prog-leave-to { opacity: 0; }
</style>
