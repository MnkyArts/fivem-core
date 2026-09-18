<script setup>
// CoreRadioGroup — one choice out of a few (DESIGN §37.5, Forms — choice).
// Renders `items` as CoreRadios and provides them the shared model, name, size and variant; a
// CoreRadio written by hand inside the default slot picks the same context up by inject.
// No roving-arrow code on purpose: real <input type="radio"> elements that share a `name` already
// get ↑/↓/←/→ from the browser, including the skip over disabled options.
import { computed, provide, toRef } from 'vue'
import { normalizeItems, oneOf, SIZES, useId } from '../use.js'

const props = defineProps({
  /** Strings or `{ value, label, description?, disabled? }` — normalised by normalizeItems. */
  items: { type: Array, default: () => [] },
  /** Shared `name` of the native inputs; generated when absent. */
  name: { type: String, default: '' },
  orientation: { type: String, default: 'vertical', validator: oneOf(['vertical', 'horizontal']) },
  /** `card` = the big selectable tile (spawn point, difficulty, payment method). */
  variant: { type: String, default: 'radio', validator: oneOf(['radio', 'card']) },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  disabled: { type: Boolean, default: false },
})

const model = defineModel({ type: null, default: undefined })

const list = computed(() => normalizeItems(props.items))
const groupName = props.name || useId('core-radiogroup')

provide('core-radio-group', {
  model,
  name: computed(() => props.name || groupName),
  disabled: toRef(props, 'disabled'),
  size: toRef(props, 'size'),
  variant: toRef(props, 'variant'),
})
</script>

<template>
  <div
    class="core-radiogroup"
    :class="[
      'core-radiogroup--' + orientation,
      'core-radiogroup--' + variant,
      { 'is-disabled': disabled },
    ]"
    role="radiogroup"
  >
    <slot>
      <CoreRadio
        v-for="(item, index) in list"
        :key="String(item.value)"
        :value="item.value"
        :label="item.label"
        :description="item.description"
        :disabled="item.disabled"
      >
        <slot name="item" :item="item" :index="index" :checked="model === item.value">{{ item.label }}</slot>
      </CoreRadio>
    </slot>
  </div>
</template>
