<script setup>
// Centred confirm/alert panel (DESIGN §6.10 `alert:open`, §7.3, §37.6): a CoreDialog with two
// CoreButtons. store.js owns Escape (-> alertResult(false)), so the dialog registers no Escape
// layer (`:escape="false"`); this component owns Enter and Tab and focuses the confirm button
// itself, so the dialog's own focus trap stays off (`:trap="false"`).
// Kit components are imported by path, never through the global registration (§37.6).
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { store, alertResult, activeModal } from '../store.js'
import CoreDialog from '../kit/components/CoreDialog.vue'
import CoreButton from '../kit/components/CoreButton.vue'

const panel = ref(null)
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

/** The buttons are DOM nodes to this component: it focuses one on open and cycles them with Tab. */
function buttons () {
  return panel.value ? Array.from(panel.value.querySelectorAll('button')) : []
}

function onKeydown (e) {
  if (activeModal() !== 'alert') return
  if (e.key === 'Enter') {
    e.preventDefault()
    const el = document.activeElement
    if (cancelLabel.value && el && el.dataset && el.dataset.role === 'cancel') cancel()
    else confirm()
  } else if (e.key === 'Tab') {
    e.preventDefault()
    const els = buttons()
    if (!els.length) return
    const i = els.indexOf(document.activeElement)
    els[e.shiftKey ? (i <= 0 ? els.length - 1 : i - 1) : ((i + 1) % els.length)].focus()
  }
}

watch([visible, () => store.alert.id], ([open]) => {
  if (!open) return
  nextTick(() => {
    const el = panel.value && panel.value.querySelector('[data-role="confirm"]')
    if (el && el.focus) el.focus()
  })
})

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <div ref="panel">
    <CoreDialog
      class="alert"
      role="alertdialog"
      :open="visible"
      :title="store.alert.title || 'Notice'"
      :aria-label="store.alert.title || 'Notice'"
      :closable="false"
      :escape="false"
      :trap="false"
      :teleport="false"
    >
      <p class="core-text msg whitespace-pre-line">{{ message }}</p>
      <template #footer>
        <CoreButton v-if="cancelLabel" data-role="cancel" @click="cancel">{{ cancelLabel }}</CoreButton>
        <CoreButton variant="primary" data-role="confirm" @click="confirm">{{ store.alert.confirm || 'OK' }}</CoreButton>
      </template>
    </CoreDialog>
  </div>
</template>
