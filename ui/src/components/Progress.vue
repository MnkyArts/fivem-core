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
    <div v-if="store.progress.visible" class="progress">
      <div class="head">
        <span class="label">{{ store.progress.label }}</span>
        <span v-if="store.progress.canCancel" class="hint"><b>X</b> to cancel</span>
      </div>
      <div class="track">
        <div ref="fillEl" class="fill"></div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.progress {
  position: fixed;
  z-index: 30;
  left: 50%;
  bottom: 7vh;
  width: 340px;
  margin-left: -170px;
  padding: 9px 11px 10px;
  background: var(--core-panel, rgba(14, 16, 20, 0.86));
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: var(--core-radius, 8px);
  pointer-events: none;
}

.head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 7px;
  font-size: 12px;
}

.label {
  color: var(--core-text, #f2f4f8);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.hint {
  flex: 0 0 auto;
  font-size: 10px;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--core-text-dim, rgba(242, 244, 248, 0.62));
}

.hint b {
  display: inline-block;
  min-width: 14px;
  margin-right: 3px;
  padding: 0 4px;
  border: 1px solid var(--core-border, rgba(255, 255, 255, 0.08));
  border-radius: 4px;
  color: var(--core-text, #f2f4f8);
}

.track {
  height: 5px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.08);
  overflow: hidden;
}

.fill {
  width: 0;
  height: 100%;
  border-radius: 3px;
  background: var(--core-accent, #5b8cff);
}

.prog-enter-active,
.prog-leave-active { transition: opacity 0.15s ease; }

.prog-enter-from,
.prog-leave-to { opacity: 0; }
</style>
