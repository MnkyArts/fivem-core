<script setup>
// CoreKeyHint — cap(s) plus a caption (DESIGN §37.5, Actions): `[ESC] BACK`.
// `keys` takes a string or a list (`['SHIFT', 'F']` -> two caps, 4 px apart); `k` is the short
// alias the shell's hint items use. The caps inherit the hint's own size and variant, so a bar
// never mixes cap heights.
import { computed } from 'vue'
import { SIZES, oneOf } from '../use.js'

const props = defineProps({
  /** `'F'`, `'ESC'`, `['SHIFT', 'F']`, or a mouse name (`'mouse-left'`). */
  keys: { type: [String, Number, Array], default: '' },
  /** Alias of `keys`, used when `keys` is empty. */
  k: { type: [String, Number, Array], default: '' },
  /** The caption after the cap(s). The default slot replaces it. */
  label: { type: String, default: '' },
  variant: { type: String, default: 'solid', validator: oneOf(['solid', 'outline']) },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
})

const empty = (v) => v === '' || v === null || v === undefined || (Array.isArray(v) && v.length === 0)

const caps = computed(() => {
  const source = empty(props.keys) ? props.k : props.keys
  const list = Array.isArray(source) ? source : [source]
  return list.filter((cap) => !empty(cap)).map((cap) => String(cap))
})
</script>

<template>
  <span class="core-keyhint" :class="'core-keyhint--' + size">
    <span v-if="caps.length" class="core-keyhint__keys">
      <CoreKey
        v-for="(cap, i) in caps"
        :key="cap + '|' + i"
        :label="cap"
        :variant="variant"
        :size="size"
      />
    </span>
    <span v-if="label || $slots.default" class="core-keyhint__label"><slot>{{ label }}</slot></span>
  </span>
</template>
