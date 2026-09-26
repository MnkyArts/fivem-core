<script setup>
// SchemaField — one §43 field drawn with kit controls; the recursive half of CoreSchemaForm
// (DESIGN §53). Not a kit component (it lives outside `kit/components/`, so it is not registered
// globally and not in the catalogue): CoreSchemaForm is the public face, this file is how it
// recurses into `object` groups and `array` rows. It refers to itself by its file name.
//
// Control per type: boolean → CoreSwitch · integer/number/heading → CoreNumberInput · string/
// password → CoreInput · text → CoreTextarea · reason → CoreTextarea + template buttons · enum →
// CoreSelect (≤ 8 options), CoreChips (multiple, ≤ 8) or CoreCombobox (> 8) · color →
// CoreColorPicker (popover) · duration → preset chips + a free `2h 30m` field · vector3/rotation →
// CoreVectorInput · model/player/ref/faction/item → CoreCombobox over `resolvers[type]` (without a
// resolver: a plain field — a digits-only server id for `player`) · array → rows + add/remove ·
// object → a nested group.
import { computed, ref, watch } from 'vue'
import { useId } from '../use.js'
import {
  DURATION_PRESETS, WORLD_MAX, WORLD_MIN, defaultFor, enumOptions, formatDuration, isVisible,
  joinPath, labelOf, messageFor, parseDuration, sortFields,
} from './schema.js'

const COMBO_OVER = 8

const props = defineProps({
  /** One `Core.Schema.public` field definition. */
  field: { type: Object, required: true },
  modelValue: { type: null, default: undefined },
  /** Error-map key of this field (`name`, `pos.x`, `list.2` — array rows count from 1, like Lua). */
  path: { type: String, default: '' },
  /** `{ [path]: code | text }` — the form's merged server + client errors. */
  errors: { type: Object, default: () => ({}) },
  resolvers: { type: Object, default: () => ({}) },
  messages: { type: Object, default: () => ({}) },
  disabled: { type: Boolean, default: false },
  /** CoreField `inline` (the settings row). */
  inline: { type: Boolean, default: false },
  /** No CoreField frame — an array row draws only the control. */
  bare: { type: Boolean, default: false },
})

const emit = defineEmits(['update:modelValue'])

const f = computed(() => props.field || {})
const t = computed(() => f.value.type)
const locked = computed(() => props.disabled || Boolean(f.value.readonly))
const label = computed(() => labelOf(f.value))
const errorText = computed(() => messageFor(props.errors[props.path], f.value, props.messages))
const value = computed(() => props.modelValue)
const set = (v) => emit('update:modelValue', v)
const fieldId = useId('core-schema')
const invalid = computed(() => Boolean(errorText.value))

/** CoreField around the control, or a bare div for an array row (see the template). */
const frame = computed(() => (props.bare
  ? { class: 'core-schemaform__bare' }
  : {
      label: label.value,
      hint: f.value.description ? String(f.value.description) : '',
      error: errorText.value,
      required: Boolean(f.value.required),
      inline: props.inline,
      id: fieldId,
    }))

const options = computed(() => enumOptions(f.value))
const resolver = computed(() => {
  const r = props.resolvers ? props.resolvers[t.value] : null
  return typeof r === 'function' ? r : null
})
const search = (query) => resolver.value(query, f.value)

/** Which control draws this field. */
const control = computed(() => {
  switch (t.value) {
    case 'boolean': return 'switch'
    case 'integer': case 'number': case 'heading': return 'number'
    case 'string': case 'password': return 'input'
    case 'text': return 'textarea'
    case 'reason': return 'reason'
    case 'enum':
      if (options.value.length > COMBO_OVER) return 'combobox'
      return f.value.multiple ? 'chips' : 'select'
    case 'color': return 'color'
    case 'duration': return 'duration'
    case 'vector3': case 'rotation': return 'vector'
    case 'array': return 'array'
    case 'object': return 'object'
    case 'model': case 'player': case 'ref': case 'faction': case 'item':
      if (resolver.value) return 'resolved'
      return t.value === 'player' ? 'serverid' : 'input'
    default: return 'input'
  }
})

// ---- numbers --------------------------------------------------------------------------------
const num = computed(() => {
  if (t.value === 'heading') return { min: 0, max: 359.99, step: 1, precision: 2, suffix: '°' }
  const integer = t.value === 'integer'
  const step = Number.isFinite(f.value.step) && f.value.step > 0 ? f.value.step : 1
  return {
    min: Number.isFinite(f.value.min) ? f.value.min : null,
    max: Number.isFinite(f.value.max) ? f.value.max : null,
    step,
    precision: integer ? 0 : Number.isFinite(f.value.step) ? null : 2,
    suffix: f.value.unit ? String(f.value.unit) : '',
  }
})
const numValue = computed(() => (typeof value.value === 'number' && Number.isFinite(value.value) ? value.value : num.value.min === null ? 0 : num.value.min))

// ---- text -----------------------------------------------------------------------------------
const maxLength = computed(() => (Number.isFinite(f.value.maxLength) ? f.value.maxLength : 256))
const textValue = computed(() => (value.value === undefined || value.value === null ? '' : String(value.value)))
/** A player without a resolver is a typed server id: digits only, empty = no value (never a fake 1). */
function setServerId (text) {
  const digits = String(text || '').replace(/[^0-9]/g, '')
  set(digits === '' ? null : Math.min(65535, Number(digits)))
}
const inputType = computed(() => (t.value === 'password' || f.value.secret ? 'password' : 'text'))
const templates = computed(() => (Array.isArray(f.value.templates) ? f.value.templates.map(String) : []))

// ---- vectors --------------------------------------------------------------------------------
const vecBounds = computed(() => {
  if (t.value === 'vector3' && f.value.world) return { min: WORLD_MIN, max: WORLD_MAX }
  return {
    min: Number.isFinite(f.value.min) ? f.value.min : null,
    max: Number.isFinite(f.value.max) ? f.value.max : null,
  }
})
const vecValue = computed(() => (value.value && typeof value.value === 'object' ? value.value : { x: 0, y: 0, z: 0 }))

// ---- duration -------------------------------------------------------------------------------
const presets = computed(() => {
  const list = Array.isArray(f.value.presets) ? f.value.presets : DURATION_PRESETS
  const out = list
    .filter((n) => Number.isFinite(n) && n > 0 && (!Number.isFinite(f.value.max) || n <= f.value.max)
      && (!Number.isFinite(f.value.min) || n >= f.value.min))
    .map((n) => ({ value: n, label: formatDuration(n), disabled: locked.value }))
  if (f.value.allowPermanent) out.push({ value: 0, label: 'Perm', disabled: locked.value })
  return out
})
const chipItems = computed(() => options.value.map((o) => Object.assign({}, o, { disabled: locked.value })))
const durationText = ref('')
const durationBad = ref(false)
const durationEditing = ref(false)
watch(value, (v) => {
  if (durationEditing.value || t.value !== 'duration') return
  durationText.value = Number.isFinite(v) ? formatDuration(v, f.value.allowPermanent) : ''
  durationBad.value = false
}, { immediate: true })
function onDurationInput (text) {
  durationText.value = String(text || '')
  const n = parseDuration(durationText.value)
  durationBad.value = durationText.value.trim() !== '' && n === null
  if (n !== null) set(n)
}
function onDurationBlur () {
  durationEditing.value = false
  if (Number.isFinite(value.value) && !durationBad.value) durationText.value = formatDuration(value.value, f.value.allowPermanent)
}

// ---- array / object ---------------------------------------------------------------------------
const rows = computed(() => (Array.isArray(value.value) ? value.value : []))
const canAdd = computed(() => !locked.value && (!Number.isFinite(f.value.maxItems) || rows.value.length < f.value.maxItems))
const canRemove = computed(() => !locked.value && (!Number.isFinite(f.value.minItems) || rows.value.length > f.value.minItems))
const itemField = computed(() => Object.assign({}, f.value.items || { type: 'string' }, { name: '', label: '' }))
function addRow () { if (canAdd.value) set(rows.value.concat([defaultFor(f.value.items || { type: 'string' })])) }
function removeRow (i) { if (canRemove.value) set(rows.value.filter((_, j) => j !== i)) }
function setRow (i, v) { set(rows.value.map((row, j) => (j === i ? v : row))) }

const objValue = computed(() => (value.value && typeof value.value === 'object' && !Array.isArray(value.value) ? value.value : {}))
const subFields = computed(() => sortFields(f.value.fields).filter((sub) => isVisible(sub, objValue.value)))
function setSub (name, v) { set(Object.assign({}, objValue.value, { [name]: v })) }
</script>

<template>
  <fieldset v-if="control === 'object'" class="core-schemaform__object" :class="{ 'is-invalid': invalid, 'is-bare': bare }">
    <legend v-if="label && !bare" class="core-schemaform__legend">{{ label }}</legend>
    <p v-if="f.description && !bare" class="core-schemaform__desc">{{ f.description }}</p>
    <SchemaField
      v-for="sub in subFields"
      :key="sub.name"
      :field="sub"
      :model-value="objValue[sub.name]"
      :path="joinPath(path, sub.name)"
      :errors="errors"
      :resolvers="resolvers"
      :messages="messages"
      :disabled="locked"
      :inline="inline"
      @update:model-value="(v) => setSub(sub.name, v)"
    />
    <p v-if="invalid" class="core-schemaform__error">{{ errorText }}</p>
  </fieldset>

  <!-- One control, two frames: CoreField (label · hint · error) or a bare div for an array row. -->
  <component :is="bare ? 'div' : 'CoreField'" v-else v-bind="frame">
    <CoreSwitch v-if="control === 'switch'" :model-value="value === true" :disabled="locked" @update:model-value="set" />

    <CoreNumberInput
      v-else-if="control === 'number'"
      :id="fieldId"
      :model-value="numValue"
      :min="num.min"
      :max="num.max"
      :step="num.step"
      :precision="num.precision === null ? undefined : num.precision"
      :suffix="num.suffix"
      :invalid="invalid"
      :disabled="locked"
      @update:model-value="set"
    />

    <CoreInput
      v-else-if="control === 'input'"
      :id="fieldId"
      :type="inputType"
      :model-value="textValue"
      :placeholder="f.placeholder ? String(f.placeholder) : ''"
      :maxlength="maxLength"
      :suffix="f.unit ? String(f.unit) : ''"
      :readonly="Boolean(f.readonly)"
      :disabled="disabled"
      :invalid="invalid"
      @update:model-value="set"
    />

    <CoreInput
      v-else-if="control === 'serverid'"
      :id="fieldId"
      inputmode="numeric"
      :model-value="textValue"
      :placeholder="f.placeholder ? String(f.placeholder) : 'Server id'"
      :maxlength="5"
      :disabled="locked"
      :invalid="invalid"
      @update:model-value="setServerId"
    />

    <CoreTextarea
      v-else-if="control === 'textarea'"
      :id="fieldId"
      :model-value="textValue"
      :placeholder="f.placeholder ? String(f.placeholder) : ''"
      :maxlength="maxLength"
      :counter="Number.isFinite(f.maxLength)"
      :readonly="Boolean(f.readonly)"
      :disabled="disabled"
      :invalid="invalid"
      @update:model-value="set"
    />

    <div v-else-if="control === 'reason'" class="core-schemaform__reason">
      <div v-if="templates.length" class="core-schemaform__templates">
        <CoreButton
          v-for="tpl in templates"
          :key="tpl"
          size="sm"
          variant="secondary"
          class="core-schemaform__template"
          :active="textValue === tpl"
          :disabled="locked"
          @click="set(tpl)"
        >{{ tpl }}</CoreButton>
      </div>
      <CoreTextarea
        :id="fieldId"
        :rows="2"
        counter
        :model-value="textValue"
        :placeholder="f.placeholder ? String(f.placeholder) : 'Reason…'"
        :maxlength="maxLength"
        :readonly="Boolean(f.readonly)"
        :disabled="disabled"
        :invalid="invalid"
        @update:model-value="set"
      />
    </div>

    <CoreSelect
      v-else-if="control === 'select'"
      :id="fieldId"
      :items="options"
      :model-value="value === undefined ? null : value"
      :placeholder="f.placeholder ? String(f.placeholder) : 'Select…'"
      :invalid="invalid"
      :disabled="locked"
      @update:model-value="set"
    />

    <CoreChips
      v-else-if="control === 'chips'"
      :items="chipItems"
      multiple
      allow-empty
      wrap
      size="sm"
      :model-value="Array.isArray(value) ? value : []"
      @update:model-value="set"
    />

    <CoreCombobox
      v-else-if="control === 'combobox' || control === 'resolved'"
      :id="fieldId"
      :options="control === 'combobox' ? options : []"
      :search="control === 'resolved' ? search : null"
      :multiple="control === 'combobox' && Boolean(f.multiple)"
      :creatable="t === 'model'"
      :clearable="!f.required"
      :model-value="value === undefined ? null : value"
      :placeholder="f.placeholder ? String(f.placeholder) : 'Search…'"
      :invalid="invalid"
      :disabled="locked"
      @update:model-value="set"
    />

    <CoreColorPicker
      v-else-if="control === 'color'"
      popover
      :id="fieldId"
      :alpha="Boolean(f.alpha)"
      :model-value="textValue"
      :invalid="invalid"
      :disabled="locked"
      @update:model-value="set"
    />

    <div v-else-if="control === 'duration'" class="core-schemaform__duration">
      <CoreChips v-if="presets.length" :items="presets" size="sm" wrap :model-value="value === undefined ? null : value" @update:model-value="set" />
      <CoreInput
        :id="fieldId"
        size="sm"
        placeholder="e.g. 2h 30m"
        :model-value="durationText"
        :invalid="durationBad || invalid"
        :disabled="locked"
        @focus="durationEditing = true"
        @blur="onDurationBlur"
        @update:model-value="onDurationInput"
      />
    </div>

    <CoreVectorInput
      v-else-if="control === 'vector'"
      :id="fieldId"
      :model-value="vecValue"
      :rotation="t === 'rotation'"
      :step="t === 'rotation' ? 0.1 : 0.01"
      :min="vecBounds.min"
      :max="vecBounds.max"
      :invalid="invalid"
      :disabled="locked"
      @update:model-value="set"
    />

    <div v-else-if="control === 'array'" class="core-schemaform__array">
      <div v-for="(row, i) in rows" :key="i" class="core-schemaform__array-row">
        <span class="core-schemaform__array-index">{{ i + 1 }}</span>
        <SchemaField
          class="core-schemaform__array-item"
          bare
          :field="itemField"
          :model-value="row"
          :path="joinPath(path, i + 1)"
          :errors="errors"
          :resolvers="resolvers"
          :messages="messages"
          :disabled="locked"
          @update:model-value="(v) => setRow(i, v)"
        />
        <CoreIconButton icon="trash" label="Remove" variant="ghost" size="sm" :disabled="!canRemove" @click="removeRow(i)" />
      </div>
      <p v-if="!rows.length" class="core-schemaform__array-empty">No entries yet.</p>
      <CoreButton class="core-schemaform__array-add" size="sm" variant="ghost" icon="plus" :disabled="!canAdd" @click="addRow">Add</CoreButton>
    </div>

    <p v-if="bare && invalid" class="core-schemaform__error">{{ errorText }}</p>
  </component>
</template>
