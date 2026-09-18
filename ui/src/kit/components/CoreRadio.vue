<script setup>
// CoreRadio — one option of a CoreRadioGroup, or a standalone radio (DESIGN §37.5).
// Inside a group it reads `{ model, name, disabled, size, variant }` from inject and writes the
// group's model; on its own it falls back to its own `v-model` and a generated `name`, so a page
// can lay four radios out by hand without a wrapper. `size`/`variant` default to null, not to
// 'md'/'radio': null is how the component tells "inherit from the group" from "forced by the caller".
import { computed, inject, useAttrs } from 'vue'
import { oneOf, SIZES, useId } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  /** The value this option stands for. */
  value: { type: null, default: undefined },
  label: { type: String, default: '' },
  /** Second line under the label, `fg-dim` — what the option means. */
  description: { type: String, default: '' },
  /** Own `name` when there is no group; ignored inside one. */
  name: { type: String, default: '' },
  disabled: { type: Boolean, default: false },
  /** null = inherit the group's size. */
  size: { type: String, default: null, validator: (v) => v === null || oneOf(SIZES)(v) },
  /** null = inherit the group's variant. */
  variant: { type: String, default: null, validator: (v) => v === null || oneOf(['radio', 'card'])(v) },
})

const model = defineModel({ type: null, default: undefined })

const group = inject('core-radio-group', null)
const attrs = useAttrs()
const ownName = useId('core-radio')

const inputAttrs = computed(() => {
  const out = {}
  for (const key of Object.keys(attrs)) {
    if (key !== 'class' && key !== 'style') out[key] = attrs[key]
  }
  return out
})

const size = computed(() => props.size || (group ? group.size.value : null) || 'md')
const variant = computed(() => props.variant || (group ? group.variant.value : null) || 'radio')
const disabled = computed(() => props.disabled || Boolean(group && group.disabled.value))
const name = computed(() => (group ? group.name.value : props.name || ownName))
const checked = computed(() => (group ? group.model.value : model.value) === props.value)

function onChange() {
  if (disabled.value) return
  if (group) group.model.value = props.value
  else model.value = props.value
}
</script>

<template>
  <label
    class="core-radio"
    :class="[
      'core-radio--' + size,
      variant === 'card' ? 'core-radio--card' : null,
      attrs.class,
      { 'is-checked': checked, 'is-disabled': disabled },
    ]"
    :style="attrs.style"
  >
    <input
      type="radio"
      v-bind="inputAttrs"
      :name="name"
      :checked="checked"
      :disabled="disabled"
      @change="onChange"
    >
    <span v-if="description" class="core-radio__body">
      <span class="core-radio__label"><slot>{{ label }}</slot></span>
      <span class="core-radio__desc">{{ description }}</span>
    </span>
    <span v-else class="core-radio__label"><slot>{{ label }}</slot></span>
  </label>
</template>
