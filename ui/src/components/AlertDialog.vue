<script setup>
// Centred confirm/alert panel (DESIGN §6.10 `alert:open`, §7.2, §7.3).
// store.js owns Escape (-> alertResult(false)); this component owns Enter and Tab.
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, alertResult, activeModal } from '../store.js'

const panel = ref(null)
const confirmEl = ref(null)
const visible = computed(() => store.alert.visible)
const message = computed(() => {
  const m = store.alert.message
  if (Array.isArray(m)) return m.join('\n')
  return (m === undefined || m === null) ? '' : String(m)
})
// `cancel: false` from Lua means a confirm-only alert.
const cancelLabel = computed(() => (store.alert.cancel === false ? '' : (store.alert.cancel || 'Cancel')))

function confirm () { alertResult(true) }
function cancel () { alertResult(false) }

function onKeydown (e) {
  if (activeModal() !== 'alert') return
  if (e.key === 'Enter') {
    e.preventDefault()
    const el = document.activeElement
    if (cancelLabel.value && el && el.dataset && el.dataset.role === 'cancel') cancel()
    else confirm()
  } else if (e.key === 'Tab') {
    e.preventDefault()
    const els = panel.value ? Array.from(panel.value.querySelectorAll('button')) : []
    if (!els.length) return
    const i = els.indexOf(document.activeElement)
    els[e.shiftKey ? (i <= 0 ? els.length - 1 : i - 1) : ((i + 1) % els.length)].focus()
  }
}

watch([visible, () => store.alert.id], ([open]) => {
  if (open) nextTick(() => { if (confirmEl.value) confirmEl.value.focus() })
})

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <Transition name="alert">
    <div v-if="visible" class="core-backdrop alert-back">
      <div ref="panel" class="core-panel core-modal alert" role="alertdialog" :aria-label="store.alert.title || 'Notice'">
        <h2 class="core-title">{{ store.alert.title || 'Notice' }}</h2>
        <p class="core-text msg">{{ message }}</p>
        <div class="actions">
          <button v-if="cancelLabel" type="button" class="core-btn" data-role="cancel" @click="cancel">
            {{ cancelLabel }}
          </button>
          <button ref="confirmEl" type="button" class="core-btn core-btn--primary" data-role="confirm" @click="confirm">
            {{ store.alert.confirm || 'OK' }}
          </button>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
.alert-back { z-index: 50; }
.alert { width: 380px; max-width: 80vw; animation: core-pop-in 0.12s var(--core-ease, ease); }
.msg { margin-top: 8px; max-height: 50vh; overflow-y: auto; white-space: pre-line; line-height: 1.5; }
.actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; }
.alert-enter-active, .alert-leave-active { transition: opacity 0.12s ease; }
.alert-enter-from, .alert-leave-to { opacity: 0; }
</style>
