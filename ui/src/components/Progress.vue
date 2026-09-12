<script setup>
// Bottom-centre progress bar (DESIGN §6.10 progress:start/stop, §7.2).
// The fill is a plain CSS width transition seeded from store.progress.startedAt, so a
// late mount still shows the right offset. store.js owns the completion timer
// (progress:start -> progressDone) and the x / Backspace cancel keys (handleKeydown).
import { ref, watch, onMounted, nextTick } from 'vue'
import { store } from '../store.js'

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
             pt-[9px] px-[11px] pb-[10px]
             bg-panel border border-border rounded-ui pointer-events-none"
    >
      <div class="head flex items-baseline justify-between gap-[10px] mb-[7px] text-ui-sm">
        <span class="label text-fg truncate">{{ store.progress.label }}</span>
        <span
          v-if="store.progress.canCancel"
          class="hint flex-none text-ui-xs tracking-[0.05em] uppercase text-fg-dim"
        ><b class="inline-block min-w-[14px] mr-[3px] px-[4px] border border-border rounded-[4px] text-fg">X</b> to cancel</span>
      </div>
      <div class="track h-[5px] rounded-[3px] bg-[rgba(255,255,255,0.08)] overflow-hidden">
        <div ref="fillEl" class="fill w-0 h-full rounded-[3px] bg-accent"></div>
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
