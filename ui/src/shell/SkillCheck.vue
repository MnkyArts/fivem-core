<script setup>
// DESIGN §40: presentation only. A reported success never authorizes a server operation.
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { activeModal, skillCheckResult, store } from '../store.js'
import CoreDialog from '../kit/components/CoreDialog.vue'
import CoreKeyHints from '../kit/components/CoreKeyHints.vue'
import CoreProgress from '../kit/components/CoreProgress.vue'

const presets = { easy: { speed: 35, areaSize: 25 }, medium: { speed: 50, areaSize: 18 }, hard: { speed: 70, areaSize: 12 } }
const stage = ref(0)
const position = ref(0)
const target = ref(50)
const visible = computed(() => store.skillcheck.visible)
const stages = computed(() => store.skillcheck.difficulty)
const current = computed(() => {
  const raw = stages.value[stage.value]
  const value = typeof raw === 'string' ? presets[raw] : raw
  return value && Number.isFinite(value.speed) && Number.isFinite(value.areaSize)
    ? { speed: Math.min(200, Math.max(20, value.speed)), areaSize: Math.min(80, Math.max(5, value.areaSize)) }
    : presets.easy
})
const key = computed(() => store.skillcheck.keys[stage.value % store.skillcheck.keys.length] || 'e')
const hints = computed(() => [{ key: key.value.toUpperCase(), label: 'Hit the highlighted area' }, ...(store.skillcheck.canCancel ? [{ key: 'Esc', label: 'Cancel' }] : [])])
let frame = 0
let last = 0
function stop() { if (frame) cancelAnimationFrame(frame); frame = 0; last = 0 }
function startStage() {
  position.value = 0
  target.value = 10 + Math.random() * (80 - current.value.areaSize)
  last = performance.now()
}
function animate(now) {
  frame = 0
  if (!visible.value) return
  if (!store.shell.visible || document.hidden) { skillCheckResult(false); return }
  position.value += Math.max(0, now - last) * current.value.speed / 1000
  last = now
  if (position.value > 100) { skillCheckResult(false); return }
  frame = requestAnimationFrame(animate)
}
function answer(event) {
  if (activeModal() !== 'skillcheck' || event.repeat || event.defaultPrevented) return
  if (event.key === 'Escape') return // the store owns cancellation and canCancel
  if (event.ctrlKey || event.altKey || event.metaKey || !/^[a-z0-9 ]$/i.test(event.key)) return
  event.preventDefault()
  if (event.key.toLowerCase() !== key.value.toLowerCase() || position.value < target.value || position.value > target.value + current.value.areaSize) {
    skillCheckResult(false); return
  }
  stage.value++
  if (stage.value >= stages.value.length) skillCheckResult(true)
  else startStage()
}
watch([visible, () => store.skillcheck.id], ([open]) => {
  stop()
  if (!open) return
  if (!stages.value.length || !store.shell.visible) { skillCheckResult(false); return }
  stage.value = 0
  startStage()
  frame = requestAnimationFrame(animate)
}, { immediate: true })
watch(() => store.shell.visible, (shown) => { if (!shown && visible.value) skillCheckResult(false) })
function visibilityChanged() { if (document.hidden && visible.value) skillCheckResult(false) }
onMounted(() => { window.addEventListener('keydown', answer); document.addEventListener('visibilitychange', visibilityChanged) })
onBeforeUnmount(() => {
  stop(); window.removeEventListener('keydown', answer); document.removeEventListener('visibilitychange', visibilityChanged)
  if (visible.value) skillCheckResult(false)
})
</script>

<template>
  <CoreDialog :open="visible" title="Skill check" :closable="false" :escape="false" :trap="false" :teleport="false">
    <CoreProgress :value="stage" :max="stages.length || 1" :label="'Stage ' + (stage + 1) + ' / ' + stages.length" size="sm" />
    <div class="skillcheck-track" role="meter" aria-label="Timing indicator" :aria-valuenow="Math.round(position)" :aria-valuemin="0" :aria-valuemax="100">
      <span class="skillcheck-target" :style="{ left: target + '%', width: current.areaSize + '%' }" />
      <span class="skillcheck-cursor" :style="{ left: position + '%' }" />
    </div>
    <template #footer><CoreKeyHints :items="hints" align="end" bare /></template>
  </CoreDialog>
</template>

<style scoped>
/* The kit has meters, but no interactive target window; geometry belongs to this widget. */
.skillcheck-track { position: relative; height: 24px; margin-top: 24px; background: var(--color-panel-sunken); overflow: hidden; }
.skillcheck-target { position: absolute; top: 0; bottom: 0; background: var(--color-accent); opacity: .55; }
.skillcheck-cursor { position: absolute; top: 0; bottom: 0; width: 3px; background: var(--color-fg); }
</style>
