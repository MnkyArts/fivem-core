<script setup>
// CoreCheckbox — the map-filter row of the mockups (DESIGN §37.5, Forms — choice).
// The root <label> wraps a REAL <input type="checkbox">: the box IS the input (restyled with
// appearance:none in css/forms-choice.css), so keyboard, :checked, :indeterminate and the click
// target of the label all come from the browser. `modelValue` may be a boolean or an ARRAY — the
// array form adds/removes `value` exactly like Vue's native multi-checkbox binding.
// inheritAttrs is off so `class`/`style` land on the label while `name`, `id` and friends reach
// the input, which is what a caller writing <CoreCheckbox name="filters"> expects.
import { computed, ref, useAttrs, watch, watchEffect } from 'vue'
import { oneOf, SIZES } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** `value` of this box inside an array model; ignored when the model is a boolean. */
  value: { type: null, default: undefined },
  /** Row label. The default slot wins over it. */
  label: { type: String, default: '' },
  /** Second line under the label, `fg-dim`. */
  description: { type: String, default: '' },
  /** Glyph between the box and the label (registry name or raw path) — the map-filter look. */
  icon: { type: String, default: '' },
  /** Neither on nor off: the box shows a white bar (a partially selected group). */
  indeterminate: { type: Boolean, default: false },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  disabled: { type: Boolean, default: false },
})

const model = defineModel({ type: [Boolean, Array], default: false })

const attrs = useAttrs()
const input = ref(null)

/** Everything except class/style: those belong to the <label>, the rest to the <input>. */
const inputAttrs = computed(() => {
  const out = {}
  for (const key of Object.keys(attrs)) {
    if (key !== 'class' && key !== 'style') out[key] = attrs[key]
  }
  return out
})

const isArray = computed(() => Array.isArray(model.value))
const checked = computed(() => (isArray.value ? model.value.indexOf(props.value) !== -1 : Boolean(model.value)))

function onChange(event) {
  if (props.disabled) return
  const on = event.target.checked
  if (!isArray.value) {
    model.value = on
    return
  }
  const next = model.value.slice()
  const i = next.indexOf(props.value)
  if (on && i === -1) next.push(props.value)
  else if (!on && i !== -1) next.splice(i, 1)
  model.value = next
}

// `indeterminate` is a DOM property, never an attribute — it has to be written on every change.
watchEffect(() => {
  if (input.value) input.value.indeterminate = props.indeterminate && !checked.value
})
watch(checked, () => {
  if (input.value) input.value.checked = checked.value
})
</script>

<template>
  <label
    class="core-check"
    :class="[
      'core-check--' + size,
      attrs.class,
      { 'is-checked': checked, 'is-indeterminate': indeterminate && !checked, 'is-disabled': disabled },
    ]"
    :style="attrs.style"
  >
    <input
      ref="input"
      type="checkbox"
      v-bind="inputAttrs"
      :checked="checked"
      :disabled="disabled"
      @change="onChange"
    >
    <slot name="icon">
      <CoreIcon v-if="icon" class="core-check__icon" :name="icon" :size="size === 'sm' ? 'sm' : 'md'" />
    </slot>
    <span v-if="description" class="core-check__body">
      <span class="core-check__label"><slot>{{ label }}</slot></span>
      <span class="core-check__desc">{{ description }}</span>
    </span>
    <span v-else class="core-check__label"><slot>{{ label }}</slot></span>
  </label>
</template>
