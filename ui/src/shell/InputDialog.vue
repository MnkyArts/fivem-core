<script setup>
// Centred input form (DESIGN §6.10 `input:open`, §7.3, §37.6): a CoreDialog of CoreFields.
// store.js owns Escape (-> inputResult(null)), so the dialog registers no Escape layer
// (`:escape="false"`); this component owns Tab and Enter, so it takes no focus trap either
// (`:trap="false"`) and focuses the first field itself.
// Kit components are imported by path, never through the global registration (§37.6).
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { store, inputResult, activeModal } from '../store.js'
import CoreDialog from '../kit/components/CoreDialog.vue'
import CoreField from '../kit/components/CoreField.vue'
import CoreInput from '../kit/components/CoreInput.vue'
import CoreSelect from '../kit/components/CoreSelect.vue'
import CoreCheckbox from '../kit/components/CoreCheckbox.vue'
import CoreButton from '../kit/components/CoreButton.vue'

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

/** `[data-field]` sits on the control the kit drew: an <input> takes focus itself, a select box
 *  hands it to the trigger button inside. */
function focusField (name) {
  const host = panel.value && panel.value.querySelector('[data-field="' + (name || '') + '"]')
  if (!host) return
  const el = host.tabIndex >= 0 ? host : host.querySelector('input, select, button')
  if (el && el.focus) el.focus()
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
  // A control that already answered the key keeps it: a kit select opens and picks with Enter,
  // and that must not submit the form behind it.
  if (e.defaultPrevented) return
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
  <div ref="panel">
    <CoreDialog
      class="dlg"
      :open="visible"
      :title="store.input.title || 'Input'"
      :aria-label="store.input.title || 'Input'"
      :closable="false"
      :escape="false"
      :trap="false"
      :teleport="false"
    >
      <!-- One CoreField per entry: it owns the control's id, the label, the asterisk and the
           error line, so `[data-error]` rides on the field it belongs to. -->
      <CoreField
        v-for="(f, i) in fields"
        :key="f.name || i"
        :label="f.type === 'checkbox' ? '' : (f.label || f.name)"
        :required="!!f.required"
        :error="errors[f.name] || ''"
        :data-error="errors[f.name] ? f.name : null"
      >
        <template #default="{ id, invalid }">
          <CoreSelect
            v-if="f.type === 'select'"
            v-model="values[f.name]"
            :id="id"
            :items="optionsOf(f)"
            :invalid="invalid"
            :data-field="f.name"
            @update:model-value="clearError(f.name)"
          />
          <CoreCheckbox
            v-else-if="f.type === 'checkbox'"
            v-model="values[f.name]"
            :data-field="f.name"
            @update:model-value="clearError(f.name)"
          >
            {{ f.label || f.name }}<em v-if="f.required" class="core-field__required">*</em>
          </CoreCheckbox>
          <CoreInput
            v-else
            v-model="values[f.name]"
            :id="id"
            :type="f.type === 'number' ? 'number' : 'text'"
            :placeholder="f.placeholder || ''"
            :invalid="invalid"
            :min="f.min"
            :max="f.max"
            :data-field="f.name"
            @update:model-value="clearError(f.name)"
          />
        </template>
      </CoreField>
      <p v-if="!fields.length" class="core-text">No fields</p>
      <template #footer>
        <CoreButton v-if="cancelLabel" data-role="cancel" @click="cancel">{{ cancelLabel }}</CoreButton>
        <CoreButton variant="primary" data-role="submit" @click="submit">{{ store.input.submit || 'OK' }}</CoreButton>
      </template>
    </CoreDialog>
  </div>
</template>
