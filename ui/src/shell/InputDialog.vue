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
import CoreTextarea from '../kit/components/CoreTextarea.vue'
import CoreSlider from '../kit/components/CoreSlider.vue'
import CoreButton from '../kit/components/CoreButton.vue'

const panel = ref(null)
const values = reactive({})
const errors = ref({})
const searches = reactive({})
const isMultiple = (f) => f.type === 'multiselect' || f.type === 'multi-select' || f.multiple === true
const isSelect = (f) => f.type === 'select' || isMultiple(f)
function filteredOptions (f) {
  const query = String(searches[f.name] || '').toLowerCase()
  return optionsOf(f).filter((option) => String(option.label).toLowerCase().includes(query))
}
function toggleOption (f, value, checked) {
  const selected = Array.isArray(values[f.name]) ? values[f.name] : []
  values[f.name] = checked ? [...new Set([...selected, value])] : selected.filter((v) => v !== value)
  clearError(f.name)
}
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
  for (const key of Object.keys(searches)) delete searches[key]
  for (const f of fields.value) {
    if (!f || !f.name) continue
    if (f.type === 'checkbox') values[f.name] = !!f.default
    else if (isMultiple(f)) values[f.name] = Array.isArray(f.default) ? [...f.default] : []
    else if (f.type === 'slider') values[f.name] = Number.isFinite(f.default) ? f.default : (f.min ?? 0)
    else if (f.type === 'color') values[f.name] = f.default || '#ffffff'
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

// Lua string bounds count UTF-8 bytes, not JavaScript UTF-16 code units.
const utf8 = new TextEncoder()
function validate () {
  const errs = {}
  for (const f of fields.value) {
    if (!f || !f.name) continue
    const raw = values[f.name]
    if (f.type === 'checkbox') {
      if (f.required && !raw) errs[f.name] = 'Required'
      continue
    }
    if (isSelect(f)) {
      const options = optionsOf(f).map((option) => option.value)
      if (isMultiple(f)) {
        if (!Array.isArray(raw) || raw.some((value) => !options.includes(value)) || new Set(raw).size !== raw.length) errs[f.name] = 'Choose valid options'
        else if (f.required && !raw.length) errs[f.name] = 'Required'
      } else if (!options.includes(raw)) errs[f.name] = 'Choose an option'
      continue
    }
    const str = (raw === undefined || raw === null) ? '' : String(raw)
    if (f.required && str === '') { errs[f.name] = 'Required'; continue }
    if (f.type === 'number' || f.type === 'slider') {
      if (str === '') continue
      const n = Number(str)
      if (!Number.isFinite(n)) errs[f.name] = 'Must be a number'
      else if (typeof f.min === 'number' && n < f.min) errs[f.name] = 'Minimum ' + f.min
      else if (typeof f.max === 'number' && n > f.max) errs[f.name] = 'Maximum ' + f.max
      else if (f.step != null) {
        const steps = (n - (f.min ?? 0)) / f.step
        if (Math.abs(steps - Math.floor(steps + 0.5)) > 0.000001) errs[f.name] = 'Use increments of ' + f.step
      }
      continue
    }
    const length = utf8.encode(str).length
    if (length < (f.minLength ?? 0)) errs[f.name] = 'Too short'
    else if (length > (f.maxLength ?? f.max ?? 256)) errs[f.name] = 'Too long'
    if (str === '') continue
    if (f.type === 'color' && !/^#[0-9a-f]{6}$/i.test(str)) errs[f.name] = 'Choose a valid color'
    if (f.type === 'time' && !/^([01]\d|2[0-3]):[0-5]\d$/.test(str)) errs[f.name] = 'Choose a valid time'
    if (f.type === 'date') {
      const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(str)
      const [year, month, day] = match ? match.slice(1).map(Number) : [0, 0, 0]
      const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
      const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
      if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1]) errs[f.name] = 'Choose a valid date'
    }
  }
  errors.value = errs
  return Object.keys(errs).length === 0
}

/** `[data-field]` sits on the control the kit drew: an <input> takes focus itself, a select box
 *  hands it to the trigger button inside. */
function focusField (name) {
  const host = panel.value && Array.from(panel.value.querySelectorAll('[data-field]')).find((el) => el.dataset.field === name)
  if (!host) return
  const el = host.tabIndex >= 0 ? host : host.querySelector('input, select, textarea, button')
  if (el && el.focus) el.focus()
}

function submit () {
  if (!validate()) return focusField(Object.keys(errors.value)[0])
  const out = {}
  for (const f of fields.value) {
    if (!f || !f.name) continue
    const raw = values[f.name]
    if (f.type === 'checkbox') out[f.name] = !!raw
    else if (f.type === 'number' || f.type === 'slider') out[f.name] = (raw === '' || raw === undefined || raw === null) ? null : Number(raw)
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
    if (e.target?.tagName === 'TEXTAREA' && !e.ctrlKey) return
    e.preventDefault()
    const el = document.activeElement
    if (el && el.dataset && el.dataset.role === 'cancel') cancel()
    else submit()
  } else if (e.key === 'Tab') {
    e.preventDefault()
    const els = panel.value ? Array.from(panel.value.querySelectorAll('input:not(:disabled), select:not(:disabled), textarea:not(:disabled), button:not(:disabled)')) : []
    if (!els.length) return
    const i = els.indexOf(document.activeElement)
    els[e.shiftKey ? (i <= 0 ? els.length - 1 : i - 1) : ((i + 1) % els.length)].focus()
  }
}

watch([visible, () => store.input.id], ([open]) => {
  if (!open) return
  reset()
  nextTick(() => focusField(fields.value.length ? fields.value[0].name : null))
}, { immediate: true })

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
          <div v-if="isSelect(f)" :data-field="f.name">
            <CoreInput v-if="f.searchable" v-model="searches[f.name]" type="search" :aria-label="'Search ' + (f.label || f.name)" placeholder="Search…" />
            <div v-if="isMultiple(f)" class="grid gap-2 max-h-48 overflow-y-auto" role="group" :aria-label="f.label || f.name">
              <CoreCheckbox v-for="option in filteredOptions(f)" :key="typeof option.value + String(option.value)"
                :model-value="(values[f.name] || []).includes(option.value)"
                @update:model-value="toggleOption(f, option.value, $event)">{{ option.label }}</CoreCheckbox>
            </div>
            <CoreSelect v-else
            v-model="values[f.name]"
            :id="id"
            :items="filteredOptions(f)"
            :invalid="invalid"
            :data-field="f.name"
            @update:model-value="clearError(f.name)"
          />
          </div>
          <CoreTextarea v-else-if="f.type === 'textarea'" v-model="values[f.name]" :id="id" :data-field="f.name" :invalid="invalid" :maxlength="f.maxLength" :placeholder="f.placeholder || ''" @update:model-value="clearError(f.name)" />
          <CoreSlider v-else-if="f.type === 'slider'" v-model="values[f.name]" :data-field="f.name" :label="f.label || f.name" :min="f.min ?? 0" :max="f.max ?? 100" :step="f.step ?? 1" show-value @update:model-value="clearError(f.name)" />
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
            :type="['number', 'password', 'date', 'time', 'color'].includes(f.type) ? f.type : 'text'"
            :placeholder="f.placeholder || ''"
            :invalid="invalid"
            :step="f.step"
            :maxlength="f.maxLength"
            :minlength="f.minLength"
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
