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
    <div v-if="visible" class="core-backdrop alert-back z-50">
      <div
        ref="panel"
        class="core-dialog core-tone-accent core-dialog--md alert animate-[core-pop-in_0.12s_var(--ease-ui)]"
        role="alertdialog" :aria-label="store.alert.title || 'Notice'" data-core-blur
      >
        <div class="core-dialog__header">
          <div class="core-dialog__titles">
            <h2 class="core-title core-dialog__title">{{ store.alert.title || 'Notice' }}</h2>
          </div>
        </div>
        <div class="core-dialog__body core-scroll">
          <p class="core-text msg whitespace-pre-line">{{ message }}</p>
        </div>
        <!-- No CoreButton here: `confirmEl` is focused as a DOM node and the buttons are what
             onKeydown() cycles with Tab, so they stay native elements wearing the kit classes. -->
        <div class="core-dialog__footer actions">
          <button v-if="cancelLabel" type="button" class="core-btn core-btn--secondary core-btn--md" data-role="cancel" @click="cancel">
            <span class="core-btn__label">{{ cancelLabel }}</span>
          </button>
          <button ref="confirmEl" type="button" class="core-btn core-btn--primary core-btn--md" data-role="confirm" @click="confirm">
            <span class="core-btn__label">{{ store.alert.confirm || 'OK' }}</span>
          </button>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Only what Vue toggles itself; everything static lives in the template's utilities. */
.alert-enter-active, .alert-leave-active { transition: opacity 0.12s ease; }
.alert-enter-from, .alert-leave-to { opacity: 0; }
</style>
