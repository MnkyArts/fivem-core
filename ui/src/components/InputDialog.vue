<script setup>
// Centred input form (DESIGN §6.10 `input:open`, §7.2, §7.3).
// store.js owns Escape (-> inputResult(null)); this component owns Tab and Enter.
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { store, inputResult, activeModal } from '../store.js'

const panel = ref(null)
const values = reactive({})
const errors = ref({})
const visible = computed(() => store.input.visible)
const fields = computed(() => (Array.isArray(store.input.fields) ? store.input.fields : []))
const cancelLabel = computed(() => (store.input.cancel === false ? '' : (store.input.cancel || 'Cancel')))

/** `options` accept `{ label, value }` objects or plain strings. */
function optionsOf (f) {
  return (Array.isArray(f.options) ? f.options : []).map((o) => (o && typeof o === 'object')
    ? { label: o.label !== undefined ? o.label : String(o.value), value: o.value }
    : { label: String(o), value: o })
}

function reset () {
  for (const k of Object.keys(values)) delete values[k]
  errors.value = {}
  for (const f of fields.value) {
    if (!f || !f.name) continue
    if (f.type === 'checkbox') values[f.name] = !!f.default
    else if (f.type === 'select') values[f.name] = f.default !== undefined ? f.default : (optionsOf(f)[0] || {}).value
    else values[f.name] = f.default !== undefined ? String(f.default) : ''
  }
}

function clearError (name) {
  if (!errors.value[name]) return
  const next = { ...errors.value }
  delete next[name]
  errors.value = next
}

function validate () {
  const errs = {}
  for (const f of fields.value) {
    if (!f || !f.name) continue
    const raw = values[f.name]
    if (f.type === 'checkbox') {
      if (f.required && !raw) errs[f.name] = 'Required'
      continue
    }
    const str = (raw === undefined || raw === null) ? '' : String(raw).trim()
    if (f.required && str === '') { errs[f.name] = 'Required'; continue }
    if (f.type === 'number' && str !== '') {
      const n = Number(str)
      if (!isFinite(n)) errs[f.name] = 'Must be a number'
      else if (typeof f.min === 'number' && n < f.min) errs[f.name] = 'Minimum ' + f.min
      else if (typeof f.max === 'number' && n > f.max) errs[f.name] = 'Maximum ' + f.max
    }
  }
  errors.value = errs
  return Object.keys(errs).length === 0
}

function focusField (name) {
  const el = panel.value && panel.value.querySelector('[data-field="' + (name || '') + '"]')
  if (el) el.focus()
}

function submit () {
  if (!validate()) return focusField(Object.keys(errors.value)[0])
  const out = {}
  for (const f of fields.value) {
    if (!f || !f.name) continue
    const raw = values[f.name]
    if (f.type === 'checkbox') out[f.name] = !!raw
    else if (f.type === 'number') out[f.name] = (raw === '' || raw === undefined || raw === null) ? null : Number(raw)
    else out[f.name] = (raw === undefined || raw === null) ? '' : raw
  }
  inputResult(out)
}

function cancel () { inputResult(null) }

function onKeydown (e) {
  if (activeModal() !== 'input') return
  if (e.key === 'Enter') {
    e.preventDefault()
    const el = document.activeElement
    if (el && el.dataset && el.dataset.role === 'cancel') cancel()
    else submit()
  } else if (e.key === 'Tab') {
    e.preventDefault()
    const els = panel.value ? Array.from(panel.value.querySelectorAll('input, select, button')) : []
    if (!els.length) return
    const i = els.indexOf(document.activeElement)
    els[e.shiftKey ? (i <= 0 ? els.length - 1 : i - 1) : ((i + 1) % els.length)].focus()
  }
}

watch([visible, () => store.input.id], ([open]) => {
  if (!open) return
  reset()
  nextTick(() => focusField(fields.value.length ? fields.value[0].name : null))
})

onMounted(() => window.addEventListener('keydown', onKeydown))
onBeforeUnmount(() => window.removeEventListener('keydown', onKeydown))
</script>

<template>
  <Transition name="dlg">
    <div v-if="visible" class="core-backdrop dlg-back z-50">
      <div
        ref="panel" class="core-panel core-modal dlg w-[380px] max-w-[80vw] animate-[core-pop-in_0.12s_var(--ease-ui)]"
        role="dialog" :aria-label="store.input.title || 'Input'" data-core-blur
      >
        <h2 class="core-title">{{ store.input.title || 'Input' }}</h2>
        <div class="fields mt-2.5 max-h-[52vh] overflow-y-auto">
          <div v-for="(f, i) in fields" :key="f.name || i" class="core-field">
            <label v-if="f.type !== 'checkbox'" class="core-label" :for="'f-' + f.name">
              {{ f.label || f.name }}<em v-if="f.required" class="ml-0.5 text-error not-italic">*</em>
            </label>
            <select
              v-if="f.type === 'select'" :id="'f-' + f.name" v-model="values[f.name]"
              class="core-select" :data-field="f.name" @change="clearError(f.name)"
            >
              <option v-for="(o, j) in optionsOf(f)" :key="j" :value="o.value">{{ o.label }}</option>
            </select>
            <label v-else-if="f.type === 'checkbox'" class="core-check">
              <input v-model="values[f.name]" type="checkbox" :data-field="f.name" @change="clearError(f.name)" />
              <span>{{ f.label || f.name }}<em v-if="f.required" class="ml-0.5 text-error not-italic">*</em></span>
            </label>
            <input
              v-else :id="'f-' + f.name" v-model="values[f.name]" class="core-input" :data-field="f.name"
              :type="f.type === 'number' ? 'number' : 'text'" :placeholder="f.placeholder || ''"
              :min="f.min" :max="f.max" @input="clearError(f.name)"
            />
            <p v-if="errors[f.name]" class="err mt-1 text-ui-xs text-error" :data-error="f.name">{{ errors[f.name] }}</p>
          </div>
          <p v-if="!fields.length" class="core-text">No fields</p>
        </div>
        <div class="actions mt-3 flex justify-end gap-2">
          <button v-if="cancelLabel" type="button" class="core-btn" data-role="cancel" @click="cancel">{{ cancelLabel }}</button>
          <button type="button" class="core-btn core-btn--primary" data-role="submit" @click="submit">
            {{ store.input.submit || 'OK' }}
          </button>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* Only what Vue toggles itself; everything static lives in the template's utilities. */
.dlg-enter-active, .dlg-leave-active { transition: opacity 0.12s ease; }
.dlg-enter-from, .dlg-leave-to { opacity: 0; }
</style>
