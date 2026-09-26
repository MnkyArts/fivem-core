<script setup>
// CoreSchemaForm — a whole form from `Core.Schema.public(fields)` (DESIGN §53 over the §43
// vocabulary, §37.5 Forms — choice). One renderer for settings (§45), admin action arguments (§51)
// and map element fields (§52): each field is drawn by the kit control its type calls for
// (kit/schema/SchemaField.vue has the table), `hidden` fields are skipped, the rest ordered by
// `order` and gathered under their `group` caption, and `visibleWhen` is re-evaluated on every
// change. The model is the values object; a missing key shows its `default` (or a neutral value)
// and is filled in on the first write, so the object that goes out is always complete.
// Errors: `errors` is the server's `{ [name] = code }` map — straight from `Core.Schema.checkAll`,
// whose nested codes carry their path (`{ list = '2.pos.min' }`, flattened here to `list.2.pos`;
// a caller may also pass flat path keys) — and always wins; a submit also runs the advisory client check (required, bounds, lengths,
// options) and keeps it live afterwards. `submit` is emitted with the values only when that check
// passes, `invalid` with the error map otherwise — the server stays the authority either way.
import { computed, ref } from 'vue'
import SchemaField from '../schema/SchemaField.vue'
import {
  checkField, fillDefaults, groupFields, isVisible, joinPath, normalizeErrors, sortFields,
} from '../schema/schema.js'

const props = defineProps({
  /** The `Core.Schema.public` array. */
  fields: { type: Array, default: () => [] },
  /** Server errors, as `Core.Schema.checkAll` returns them (`{ name = code | 'custom:<text>' | '2.pos.min' }`). */
  errors: { type: Object, default: () => ({}) },
  /** `{ player | model | ref | faction | item: (query, field) => Option[] | Promise<Option[]> }` */
  resolvers: { type: Object, default: () => ({}) },
  /** Wording per error code (`{ required: 'Pflichtfeld.' }`); `{min}`-style holes are filled. */
  messages: { type: Object, default: () => ({}) },
  /** Settings rows: label left, control right (CoreField `inline`). */
  inline: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  /** A primary submit button in the footer; `''` = none (the caller's dialog owns the buttons). */
  submitLabel: { type: String, default: '' },
  /** The submit button spins. */
  busy: { type: Boolean, default: false },
})

const emit = defineEmits(['submit', 'invalid'])
const model = defineModel({ type: Object, default: () => ({}) })

const checked = ref(false)

const values = computed(() => fillDefaults(props.fields, model.value))
const groups = computed(() => groupFields(props.fields)
  .map((group) => ({ name: group.name, fields: group.fields.filter((field) => isVisible(field, values.value)) }))
  .filter((group) => group.fields.length > 0))

/** The advisory client check, recursively through objects and array rows. */
function collect (fields, vals, prefix, out) {
  for (const field of sortFields(fields)) {
    if (!field.name || !isVisible(field, vals)) continue
    const path = joinPath(prefix, field.name)
    const v = vals ? vals[field.name] : undefined
    const code = checkField(field, v)
    if (code) { out[path] = code; continue }
    if (field.type === 'object') collect(field.fields, v || {}, path, out)
    else if (field.type === 'array' && Array.isArray(v) && field.items) {
      v.forEach((item, i) => {
        const itemPath = joinPath(path, i + 1)
        const c = checkField(field.items, item)
        if (c) out[itemPath] = c
        else if (field.items.type === 'object') collect(field.items.fields, item || {}, itemPath, out)
      })
    }
  }
  return out
}

const clientErrors = computed(() => (checked.value ? collect(props.fields, values.value, '', {}) : {}))
const shownErrors = computed(() => Object.assign({}, clientErrors.value, normalizeErrors(props.errors)))

function setField (name, v) {
  model.value = Object.assign({}, values.value, { [name]: v })
}

/** Runs the client check; returns `{ [path]: code }` (empty = passes). */
function validate () {
  checked.value = true
  return collect(props.fields, values.value, '', {})
}

function submit () {
  if (props.disabled || props.busy) return
  const errs = validate()
  if (Object.keys(errs).length) { emit('invalid', errs); return }
  emit('submit', values.value)
}

defineExpose({ submit, validate })
</script>

<template>
  <form
    class="core-schemaform"
    :class="{ 'core-schemaform--inline': inline, 'is-disabled': disabled }"
    novalidate
    @submit.prevent="submit"
  >
    <section
      v-for="group in groups"
      :key="group.name || '_'"
      class="core-schemaform__group"
      :class="{ 'has-title': group.name }"
    >
      <p v-if="group.name" class="core-schemaform__group-title">{{ group.name }}</p>
      <SchemaField
        v-for="field in group.fields"
        :key="field.name"
        :field="field"
        :model-value="values[field.name]"
        :path="field.name"
        :errors="shownErrors"
        :resolvers="resolvers"
        :messages="messages"
        :disabled="disabled"
        :inline="inline"
        @update:model-value="(v) => setField(field.name, v)"
      />
    </section>
    <p v-if="!groups.length" class="core-schemaform__empty">Nothing to configure.</p>

    <slot name="footer" :submit="submit" :errors="shownErrors">
      <div v-if="submitLabel" class="core-schemaform__footer">
        <CoreButton type="submit" variant="primary" :loading="busy" :disabled="disabled">{{ submitLabel }}</CoreButton>
      </div>
    </slot>
  </form>
</template>
