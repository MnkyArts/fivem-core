<script setup>
// CoreSwitch — an on/off setting (DESIGN §37.5, Forms — choice).
// The only control of the group whose input is not the paint: Chromium renders no ::before /
// ::after on a void <input>, and the thumb has to live inside the track. The input is therefore
// visually hidden (1 px, opacity 0 — never display:none, which would drop it out of the tab
// order) and the sibling track reads `:checked` / `:focus-visible` through the `+` combinator.
// `labelPosition` defaults to 'left' (§37.5 order): label left, switch right, the settings row.
import { computed, useAttrs } from 'vue'
import { oneOf, SIZES } from '../use.js'

defineOptions({ inheritAttrs: false })

const props = defineProps({
  label: { type: String, default: '' },
  /** Second line under the label, `fg-dim`. */
  description: { type: String, default: '' },
  /** `left` = label then switch (settings row); `right` = switch then label. */
  labelPosition: { type: String, default: 'left', validator: oneOf(['left', 'right']) },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  disabled: { type: Boolean, default: false },
})

const model = defineModel({ type: Boolean, default: false })

const attrs = useAttrs()

const inputAttrs = computed(() => {
  const out = {}
  for (const key of Object.keys(attrs)) {
    if (key !== 'class' && key !== 'style') out[key] = attrs[key]
  }
  return out
})

function onChange(event) {
  if (props.disabled) return
  model.value = event.target.checked
}
</script>

<template>
  <label
    class="core-switch"
    :class="[
      'core-switch--' + size,
      labelPosition === 'left' ? 'core-switch--left' : null,
      attrs.class,
      { 'is-on': model, 'is-disabled': disabled },
    ]"
    :style="attrs.style"
  >
    <input
      class="core-switch__input"
      type="checkbox"
      role="switch"
      v-bind="inputAttrs"
      :checked="model"
      :disabled="disabled"
      @change="onChange"
    >
    <span class="core-switch__track"><span class="core-switch__thumb"></span></span>
    <span v-if="label || description || $slots.default" class="core-switch__body">
      <span class="core-switch__label"><slot>{{ label }}</slot></span>
      <span v-if="description" class="core-switch__desc">{{ description }}</span>
    </span>
  </label>
</template>
